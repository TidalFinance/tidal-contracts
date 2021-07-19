// SPDX-License-Identifier: MIT
pragma solidity 0.6.12;

import "@openzeppelin/contracts/access/Ownable.sol";

import "./interfaces/IAssetManager.sol";

// This contract is owned by Timelock.
contract AssetManager is IAssetManager, Ownable {

    struct Asset {
        address token;
        uint8 category;  // 0 - low, 1 - medium, 2 - high
    }

    uint8 public categoryLength;

    Asset[] public assets;  // Every asset have a unique index.

    mapping(uint8 => uint16[]) private indexesByCategory;

    function setCategoryLength(uint8 length_) external onlyOwner {
        categoryLength = length_;
    }

    function setAsset(uint16 index_, address token_, uint8 category_) external onlyOwner {
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

    // Anyone can call this function, but it doesn't matter.
    function resetIndexesByCategory(uint8 category_) external {
        delete indexesByCategory[category_];

        for (uint16 i = 0; i < uint16(assets.length); ++i) {
            if (assets[i].category == category_) {
                indexesByCategory[category_].push(i);
            }
        }
    }

    function getCategoryLength() external override view returns(uint8) {
        return categoryLength;
    }

    function getAssetLength() external override view returns(uint256) {
        return assets.length;
    }

    function getAssetToken(uint16 index_) external override view returns(address) {
        return assets[index_].token;
    }

    function getAssetCategory(uint16 index_) external override view returns(uint8) {
        return assets[index_].category;
    }

    function getIndexesByCategory(uint8 category_, uint256 categoryIndex_) external override view returns(uint16) {
        return indexesByCategory[category_][categoryIndex_];
    }

    function getIndexesByCategoryLength(uint8 category_) external override view returns(uint256) {
        return indexesByCategory[category_].length;
    }
}
