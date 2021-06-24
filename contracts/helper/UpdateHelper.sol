// SPDX-License-Identifier: MIT
pragma solidity 0.6.12;

import "../interfaces/IRegistry.sol";
import "../interfaces/ISeller.sol";
import "../interfaces/IGuarantor.sol";

contract UpdateHelper {
    
    IRegistry public registry;
    
    constructor (IRegistry registry_) public {
        registry = registry_;
    }
    
    function update(address who_) external {
        ISeller(registry.seller()).update(who_);
        IGuarantor(registry.guarantor()).update(who_);
    }
}
