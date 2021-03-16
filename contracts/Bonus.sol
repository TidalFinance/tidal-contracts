// SPDX-License-Identifier: MIT
pragma solidity 0.6.12;

import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/math/SafeMath.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import "./interfaces/IBonus.sol";
import "./interfaces/IBuyer.sol";
import "./interfaces/IGuarantor.sol";
import "./interfaces/ISeller.sol";


// This contract is owned by Timelock.
contract Bonus is IBonus, Ownable {

    IERC20 public tidalToken;

    IBuyer public buyer;
    IGuarantor public guarantor;
    ISeller public seller;

    uint256 public bonusPerAssetOfG = 1000e18;
    uint256 public bonusPerCategoryOfS = 10000e18;
    uint256 public bonusPerAssetOfB = 1000e18;

    constructor () public { }

    function setTidalToken(IERC20 tidalToken_) external onlyOwner {
        tidalToken = tidalToken_;
    }

    function setBuyer(IBuyer buyer_) external onlyOwner {
        buyer = buyer_;
    }

    function setSeller(ISeller seller_) external onlyOwner {
        seller = seller_;
    }

    function setGuarantor(IGuarantor guarantor_) external onlyOwner {
        guarantor = guarantor_;
    }

    function setBonusPerAssetOfG(uint256 value_) external onlyOwner {
        bonusPerAssetOfG = value_;
    }

    function setBonusPerCategoryOfS(uint256 value_) external onlyOwner {
        bonusPerCategoryOfS = value_;
    }

    function setBonusPerAssetOfB(uint256 value_) external onlyOwner {
        bonusPerAssetOfB = value_;
    }

    function updateBuyerBonus(uint256 assetIndex_) external {
        tidalToken.approve(address(buyer), bonusPerAssetOfB);
        buyer.updateBonus(assetIndex_, bonusPerAssetOfB);
    }

    function updateSellerBonus(uint8 category_) external {
        tidalToken.approve(address(seller), bonusPerCategoryOfS);
        seller.updateBonus(category_, bonusPerCategoryOfS);
    }

    function updateGuarantorBonus(uint256 assetIndex_) external {
        tidalToken.approve(address(guarantor), bonusPerAssetOfB);
        guarantor.updateBonus(assetIndex_, bonusPerAssetOfG);
    }
}
