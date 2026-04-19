// validation_flaw.cpp
// Target: CChainState::ConnectBlock – bloc cu tranzacții care depășește sigops limit
#include <validation.h>
#include <consensus/validation.h>

class ValidationFlawExploit {