// SPDX-License-Identifier: MIT
pragma solidity 0.6.12;

import "@openzeppelin/contracts/access/Ownable.sol";

import "./interfaces/IAssetManager.sol";


// This contract is owned by Timelock.
contract AssetManager is IAssetManager, Ownable {

    struct Asset {
        address token;
        uint8 category;  // 0 - low, 1 - medium, 2 - high
        bool deprecated;
    }

    Asset[] public assets;  // Every asset have a unique index.

    mapping(uint8 => uint256[]) private indexesByCategory;

    function setAsset(uint256 index_, address token_, uint8 category_) external onlyOwner {
        if (index_ < assets.length) {
            assets[index_].token = token_;
            assets[index_].category = category_;
        } else {
            Asset memory asset;
            asset.token = token_;
            asset.category = category_;
            assets.push(asset);
        }
    }

    function resetIndexesByCategory(uint8 category_) external {
        delete indexesByCategory[category_];

        for (uint256 i = 0; i < assets.length; ++i) {
            if (assets[i].category == category_ && !assets[i].deprecated) {
                indexesByCategory[category_].push(i);
            }
        }
    }

    function getCategoryLength() external override view returns(uint8) {
        return 3;  // May update in the future.
    }

    function getAssetLength() external override view returns(uint256) {
        return assets.length;
    }

    function getAssetToken(uint256 index_) external override view returns(address) {
        return assets[index_].token;
    }

    function getAssetCategory(uint256 index_) external override view returns(uint8) {
        return assets[index_].category;
    }

    function getAssetDeprecated(uint256 index_) external override view returns(uint8) {
        return assets[index_].deprecated;
    }

    function getIndexesByCategory(uint8 category_, uint256 categoryIndex_) external override view returns(uint256) {
        return indexesByCategory[category_][categoryIndex_];
    }

    function getIndexesByCategoryLength(uint8 category_) external override view returns(uint256) {
        return indexesByCategory[category_].length;
    }
}
