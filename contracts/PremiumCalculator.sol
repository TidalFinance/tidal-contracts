// SPDX-License-Identifier: MIT
pragma solidity 0.6.12;

import "@openzeppelin/contracts/access/Ownable.sol";

import "./interfaces/IAssetManager.sol";
import "./interfaces/IBuyer.sol";
import "./interfaces/IPremiumCalculator.sol";
import "./interfaces/IRegistry.sol";

contract PremiumCalculator is IPremiumCalculator, Ownable {

    IRegistry public registry;

    mapping(uint16 => uint256) private premiumRate;

    constructor (IRegistry registry_) public {
        registry = registry_;
    }

    function setPremiumRate(uint16 assetIndex_, uint256 rate_) external onlyOwner {
        premiumRate[assetIndex_] = rate_;
    }

    function getPremiumRate(uint16 assetIndex_) external override view returns(uint256) {
        return premiumRate[assetIndex_];
    }
}
