// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @title OmnibusHTLC
/// @notice Hash Time-Locked Contract for atomic swaps between Omnibus blockchain
///         and EVM chains (ETH, Base, BNB, etc). Uses sha256 (not keccak256)
///         to interoperate with Bitcoin and Omnibus hash locks.
contract OmnibusHTLC {
    struct Lock {
        address sender;
        address recipient;
        uint256 amount;
        bytes32 hashLock;
        uint256 timelock;       // block.number after which refund() is allowed
        bool claimed;
        bool refunded;
    }

    mapping(bytes32 => Lock) public locks;

    event HTLCInit(
        bytes32 indexed id,
        address indexed sender,
        address indexed recipient,
        uint256 amount,
        bytes32 hashLock,
        uint256 timelock
    );
    event HTLCClaim(bytes32 indexed id, bytes32 preimage);
    event HTLCRefund(bytes32 indexed id);

    error AmountZero();
    error BadTimelock();
    error AlreadyExists();
    error NotFound();
    error AlreadySettled();
    error BadPreimage();
    error NotRecipient();
    error TooEarly();
    error NotSender();
    error TransferFailed();

    /// @notice Create a new HTLC. Sender locks msg.value to recipient.
    function init(address recipient, bytes32 hashLock, uint256 timelock)
        external payable returns (bytes32 id)
    {
        if (msg.value == 0) revert AmountZero();
        if (timelock <= block.number) revert BadTimelock();

        id = keccak256(abi.encodePacked(
            msg.sender, recipient, msg.value, hashLock, timelock, block.number
        ));
        if (locks[id].sender != address(0)) revert AlreadyExists();

        locks[id] = Lock(msg.sender, recipient, msg.value, hashLock, timelock, false, false);
        emit HTLCInit(id, msg.sender, recipient, msg.value, hashLock, timelock);
    }

    /// @notice Recipient claims by revealing the preimage.
    function claim(bytes32 id, bytes32 preimage) external {
        Lock storage L = locks[id];
        if (L.sender == address(0)) revert NotFound();
        if (L.claimed || L.refunded) revert AlreadySettled();
        if (sha256(abi.encodePacked(preimage)) != L.hashLock) revert BadPreimage();
        if (msg.sender != L.recipient) revert NotRecipient();

        L.claimed = true;
        (bool ok,) = L.recipient.call{value: L.amount}("");
        if (!ok) revert TransferFailed();
        emit HTLCClaim(id, preimage);
    }

    /// @notice Sender refunds after timelock expires.
    function refund(bytes32 id) external {
        Lock storage L = locks[id];
        if (L.sender == address(0)) revert NotFound();
        if (L.claimed || L.refunded) revert AlreadySettled();
        if (block.number < L.timelock) revert TooEarly();
        if (msg.sender != L.sender) revert NotSender();

        L.refunded = true;
        (bool ok,) = L.sender.call{value: L.amount}("");
        if (!ok) revert TransferFailed();
        emit HTLCRefund(id);
    }

    /// @notice View helper.
    function getLock(bytes32 id) external view returns (Lock memory) {
        return locks[id];
    }
}
