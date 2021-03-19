// SPDX-License-Identifier: MIT
pragma solidity 0.6.12;

interface IAssetManager {
    function getCategoryLength() external view returns(uint8);
    function getAssetLength() external view returns(uint256);
    function getAssetToken(uint256 index_) external view returns(address);
    function getAssetCategory(uint256 index_) external view returns(uint8);
    function getAssetDeprecated(uint256 index_) external view returns(bool);
    function getIndexesByCategory(uint8 category_, uint256 index_) external view returns(uint256);
    function getIndexesByCategoryLength(uint8 category_) external view returns(uint256);
}
