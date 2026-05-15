// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @title OmnibusDEX
/// @notice On-EVM escrow for OmniBus limit orders. The user locks an ERC-20
///         amount when placing a buy order; the order remains visible to the
///         OmniBus chain via events. Settlement is initiated exclusively by
///         the OmniBus operator key when a fill happens on the OmniBus
///         orderbook. Cancellation is permissionless for the order owner.
///
///         Design goals (per founder spec, 2026-05-14):
///           1. NO depozit la OmniBus — funds stay on user's chain, in this
///              contract as escrow. User retains ownership rights via
///              cancelOrder.
///           2. NO preimage / HTLC ping-pong — single settle() call from the
///              relayer is enough at fill time.
///           3. NO MetaMask requirement — frontend signs raw EIP-155 tx with
///              the EVM child key derived from the OmniBus mnemonic.
///           4. CHAIN-NATIVE — OmniBus chain alone can drive settlement; if
///              the frontend goes offline, anyone who controls the operator
///              key (the chain node itself) can keep settling pending orders.
///
///         Universal: deploy the same bytecode on Ethereum mainnet, Base,
///         BNB, Polygon, Sepolia, Base Sepolia, Arb Sepolia, OP Sepolia,
///         Polygon Amoy, Avalanche Fuji. Each deployment is independent;
///         the OmniBus chain knows the contract address per chain from
///         frontend/src/api/chains.ts.
///
/// @dev    Native ETH/coin support is intentionally NOT added — only ERC-20
///         tokens. Users wanting to trade ETH for OMNI use the WETH wrapper.
///         This keeps the contract small and audit-friendly.
interface IERC20 {
    function transferFrom(address from, address to, uint256 amount) external returns (bool);
    function transfer(address to, uint256 amount) external returns (bool);
    function balanceOf(address who) external view returns (uint256);
}

contract OmnibusDEX {
    // ── State ───────────────────────────────────────────────────────────────

    /// @notice The OmniBus operator key allowed to call settle(). Set once at
    ///         deploy and immutable afterwards. The chain node uses a key
    ///         derived from the founder mnemonic at BIP-44 path
    ///         m/44'/60'/0'/0/2 (exchange.omnibus registrar slot).
    address public immutable operator;

    /// @dev Order ids are assigned by the OmniBus chain so the EVM contract
    ///      and the chain can both reference the same id without a separate
    ///      reservation step. The chain MUST ensure uniqueness; if the user
    ///      submits a duplicate id, the contract rejects.
    struct Order {
        address owner;        // who locked funds (refundable via cancelOrder)
        address token;        // ERC-20 escrowed (USDC, EURC, LCX, etc.)
        uint256 amount;       // amount locked (in token's smallest unit)
        bytes32 omniRecipient;// 32-byte OmniBus address of the OMNI seller
                              // (so the chain knows where to credit OMNI)
        uint64  expiresAt;    // unix seconds — past which user can self-cancel
                              // even before the operator settles
        uint8   state;        // 0 = empty, 1 = open, 2 = settled, 3 = cancelled
    }

    mapping(uint256 => Order) public orders;

    // ── Events ──────────────────────────────────────────────────────────────

    /// @dev OmniBus chain listens to OrderPlaced via eth_getLogs filtering
    ///      by this address. omniRecipient lets the chain map the EVM-side
    ///      escrow to the OmniBus seller wallet at fill time.
    event OrderPlaced(
        uint256 indexed orderId,
        address indexed owner,
        address indexed token,
        uint256 amount,
        bytes32 omniRecipient,
        uint64  expiresAt
    );
    event OrderSettled(uint256 indexed orderId, address indexed seller, uint256 amount);
    event OrderCancelled(uint256 indexed orderId, address indexed owner, uint256 amount);

    // ── Errors ──────────────────────────────────────────────────────────────

    error NotOperator();
    error NotOwner();
    error AmountZero();
    error AlreadyExists();
    error NotFound();
    error NotOpen();
    error TransferFromFailed();
    error TransferFailed();
    error TooEarly();

    // ── Constructor ─────────────────────────────────────────────────────────

    constructor(address _operator) {
        require(_operator != address(0), "operator=0");
        operator = _operator;
    }

    // ── User-facing: place + cancel ────────────────────────────────────────

    /// @notice Lock `amount` of `token` as escrow for a buy order on the
    ///         OmniBus orderbook. The user must have approved this contract
    ///         to spend `amount` of `token` beforehand (standard ERC-20
    ///         allowance pattern).
    /// @param  orderId       Unique id the OmniBus chain assigned. The chain
    ///                       picks a 64-bit nonce; the contract refuses if
    ///                       the id was already used.
    /// @param  token         ERC-20 contract on this chain (USDC mainnet,
    ///                       USDC Sepolia, LCX Liberty, EURC, etc.).
    /// @param  amount        Token-side amount (e.g. 1000 USDC = 1_000_000_000
    ///                       at 6 decimals).
    /// @param  omniRecipient OmniBus seller's address as raw 32 bytes (the
    ///                       chain encodes the 39+ char `ob1q...` as a hash
    ///                       since EVM has no native bech32 type).
    /// @param  expiresAt     Unix seconds after which the owner can cancel
    ///                       unconditionally. Until then the operator has
    ///                       priority; orderbook timeouts are enforced
    ///                       chain-side.
    function placeBuyOrder(
        uint256 orderId,
        address token,
        uint256 amount,
        bytes32 omniRecipient,
        uint64  expiresAt
    ) external {
        if (amount == 0) revert AmountZero();
        if (orders[orderId].state != 0) revert AlreadyExists();

        // Pull funds into escrow. transferFrom may return false on weird
        // tokens (USDT-style) so check explicitly.
        bool ok = IERC20(token).transferFrom(msg.sender, address(this), amount);
        if (!ok) revert TransferFromFailed();

        orders[orderId] = Order({
            owner:         msg.sender,
            token:         token,
            amount:        amount,
            omniRecipient: omniRecipient,
            expiresAt:     expiresAt,
            state:         1 // open
        });

        emit OrderPlaced(orderId, msg.sender, token, amount, omniRecipient, expiresAt);
    }

    /// @notice Native-ETH variant of placeBuyOrder. User sends ETH along
    ///         with the call (msg.value = amount). Stored as token=address(0)
    ///         to signal "native". Used for OMNI/ETH pair where the buyer
    ///         wants to pay with chain-native ETH instead of wrapping into
    ///         WETH first. settle() / cancelOrder() / expireRefund() check
    ///         token == address(0) and send ETH back via .call instead of
    ///         IERC20.transfer.
    function placeBuyOrderNative(
        uint256 orderId,
        bytes32 omniRecipient,
        uint64  expiresAt
    ) external payable {
        if (msg.value == 0) revert AmountZero();
        if (orders[orderId].state != 0) revert AlreadyExists();

        orders[orderId] = Order({
            owner:         msg.sender,
            token:         address(0),     // sentinel: native ETH
            amount:        msg.value,
            omniRecipient: omniRecipient,
            expiresAt:     expiresAt,
            state:         1 // open
        });

        emit OrderPlaced(orderId, msg.sender, address(0), msg.value, omniRecipient, expiresAt);
    }

    /// @notice Order owner cancels and gets escrow back. Allowed any time the
    ///         order is still open, even before expiresAt — the OmniBus
    ///         orderbook treats the cancel event as authoritative once seen.
    function cancelOrder(uint256 orderId) external {
        Order storage O = orders[orderId];
        if (O.state != 1) revert NotOpen();
        if (msg.sender != O.owner) revert NotOwner();

        O.state = 3; // cancelled
        _payout(O.owner, O.token, O.amount);
        emit OrderCancelled(orderId, O.owner, O.amount);
    }

    // ── Operator-facing: settle ────────────────────────────────────────────

    /// @notice Operator (= OmniBus chain) settles a filled order by sending
    ///         the escrowed tokens to the seller's EVM address. Called only
    ///         after the chain has internally moved OMNI from seller to buyer
    ///         on the OmniBus side. Atomicity is guaranteed at the operator
    ///         level: the chain debits OMNI first, then submits settle() and
    ///         waits for confirmation; if the EVM tx reverts (e.g. token
    ///         frozen), the chain rolls back the OMNI move.
    /// @param  orderId  the matching id from OrderPlaced.
    /// @param  seller   the EVM address of the OMNI seller — gets the
    ///                  escrowed tokens.
    function settle(uint256 orderId, address seller) external {
        if (msg.sender != operator) revert NotOperator();
        Order storage O = orders[orderId];
        if (O.state != 1) revert NotOpen();

        O.state = 2; // settled
        _payout(seller, O.token, O.amount);
        emit OrderSettled(orderId, seller, O.amount);
    }

    // ── Owner safety: cancel after expiry without operator ─────────────────

    /// @notice Anyone may call after expiresAt to refund the escrow to the
    ///         original owner. This is the emergency path if the operator
    ///         (chain) is offline for an extended period — the user gets
    ///         their money back without needing the operator's signature.
    function expireRefund(uint256 orderId) external {
        Order storage O = orders[orderId];
        if (O.state != 1) revert NotOpen();
        if (block.timestamp < O.expiresAt) revert TooEarly();

        O.state = 3; // cancelled
        _payout(O.owner, O.token, O.amount);
        emit OrderCancelled(orderId, O.owner, O.amount);
    }

    // ── Internal payout helper ─────────────────────────────────────────────
    //
    // Dispatches the actual asset move: native ETH via .call when token =
    // address(0), ERC-20 via IERC20.transfer otherwise. Reverts on failure
    // so the surrounding state mutation gets rolled back atomically.
    function _payout(address to, address token, uint256 amount) internal {
        if (token == address(0)) {
            (bool sent, ) = payable(to).call{value: amount}("");
            if (!sent) revert TransferFailed();
        } else {
            bool ok = IERC20(token).transfer(to, amount);
            if (!ok) revert TransferFailed();
        }
    }

    // ── View ───────────────────────────────────────────────────────────────

    function getOrder(uint256 orderId) external view returns (Order memory) {
        return orders[orderId];
    }
}
