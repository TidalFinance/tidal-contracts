// SPDX-License-Identifier: MIT
pragma solidity 0.6.12;

import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/math/SafeMath.sol";

import "./interfaces/IAssetManager.sol";


// This contract is owned by Timelock.
contract AssetManager is IAssetManager, Ownable {

    struct Asset {
        address token;
        address policy;
        uint256 riskLevel;  // 0 - low, 1 - medium, 2 - high
    }

    Asset[] public assets;  // Every asset have a unique index.

    function setAsset(uint256 index_, address token_, address policy_, uint256 riskLevel_) external onlyOwner {
        if (index_ < assets.length) {
            assets[index_].token = token_;
            assets[index_].policy = policy_;
            assets[index_].riskLevel = riskLevel_;
        } else {
            Asset memory asset;
            asset.token = token_;
            asset.policy = policy_;
            asset.riskLevel = riskLevel_;
            assets.push(asset);
        }
    }

    function getAssetLength() external override view returns(uint256) {
        return assets.length;
    }

    function getAssetToken(uint256 index_) external override view returns(address) {
        return assets[index_].token;
    }

    function getAssetPolicy(uint256 index_) external override view returns(address) {
        return assets[index_].policy;
    }

    function getAssetRiskLevel(uint256 index_) external override view returns(uint256) {
        return assets[index_].riskLevel;
    }
}
