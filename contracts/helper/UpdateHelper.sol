// SPDX-License-Identifier: MIT
pragma solidity 0.6.12;

import "@openzeppelin/contracts/access/Ownable.sol";

import "../interfaces/IRegistry.sol";
import "../Seller.sol";
import "../Guarantor.sol";

contract UpdateHelper is Ownable {
    
    IRegistry public registry;
    
    constructor () public {
    }
    
    function setRegistry(IRegistry registry_) external onlyOwner {
        registry = registry_;
    }
    
    function update(address who_) external {
        Seller(registry.seller()).update(who_);
        Guarantor(registry.guarantor()).update(who_);
    }
}