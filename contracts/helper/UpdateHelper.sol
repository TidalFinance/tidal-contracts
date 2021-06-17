// SPDX-License-Identifier: MIT
pragma solidity 0.6.12;

import "@openzeppelin/contracts/access/Ownable.sol";

import "../interfaces/IRegistry.sol";
import "../interfaces/ISeller.sol";
import "../interfaces/IGuarantor.sol";

contract UpdateHelper is Ownable {
    
    IRegistry public registry;
    
    constructor () public {
    }
    
    function setRegistry(IRegistry registry_) external onlyOwner {
        registry = registry_;
    }
    
    function update(address who_) external {
        ISeller(registry.seller()).update(who_);
        IGuarantor(registry.guarantor()).update(who_);
    }
}