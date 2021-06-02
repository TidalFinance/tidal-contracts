// SPDX-License-Identifier: MIT
pragma solidity 0.6.12;

import "./interfaces/IAssetManager.sol";
import "./interfaces/IBuyer.sol";
import "./interfaces/IPremiumCalculator.sol";
import "./interfaces/IRegistry.sol";

contract PremiumCalculator is IPremiumCalculator {

    // The base of utilization.
    uint256 constant UTILIZATION_BASE = 1e6;

    IRegistry public registry;

    constructor (IRegistry registry_) public {
        registry = registry_;
    }

    function getPremiumRate(uint16 assetIndex_) public override view returns(uint256) {
        uint8 category = IAssetManager(registry.assetManager()).getAssetCategory(assetIndex_);
        uint256 assetUtilization = IBuyer(registry.buyer()).assetUtilization(assetIndex_);

        uint256 extra;
        uint256 cap = UTILIZATION_BASE * 8 / 10;  // 80%

        if (assetUtilization >= cap) {
            extra = 1000;
        } else {
            extra = 1000 * assetUtilization / cap;
        }

        if (category == 0) {
            return 500 + extra;
        } else if (category == 1) {
            return 1135 + extra;
        } else {
            return 2173 + extra;
        }
    }
}
