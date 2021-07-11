// SPDX-License-Identifier: MIT
pragma solidity 0.6.12;

import "../interfaces/IRegistry.sol";
import "../interfaces/ISeller.sol";
import "../interfaces/IGuarantor.sol";

import "../common/BaseRelayRecipient.sol";

contract UpdateHelper is BaseRelayRecipient {

    string public override versionRecipient = "1.0.0";

    IRegistry public registry;

    constructor (IRegistry registry_) public {
        registry = registry_;
    }

    function _trustedForwarder() internal override view returns(address) {
        return registry.trustedForwarder();
    }
    
    function update(address who_) external {
        ISeller(registry.seller()).update(who_);
        IGuarantor(registry.guarantor()).update(who_);
    }
}
