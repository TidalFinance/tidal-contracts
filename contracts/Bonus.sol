// SPDX-License-Identifier: MIT
pragma solidity 0.6.12;

import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/math/SafeMath.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import "./WeekManaged.sol";

import "./interfaces/IBonus.sol";
import "./interfaces/IBuyer.sol";
import "./interfaces/IGuarantor.sol";
import "./interfaces/ISeller.sol";


// This contract is owned by Timelock.
contract Bonus is IBonus, Ownable, WeekManaged {

    IERC20 public tidalToken;

    IBuyer public buyer;
    IGuarantor public guarantor;
    ISeller public seller;

    uint256 public bonusPerAssetOfG = 1000e18;
    uint256 public bonusPerCategoryOfS = 10000e18;
    uint256 public bonusPerAssetOfB = 1000e18;

    // assetIndex => week
    mapping(uint256 => uint256) public buyerWeek;
    // category => week
    mapping(uint8 => uint256) public sellerWeek;
    // assetIndex => week
    mapping(uint256 => uint256) public guarantorWeek;

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
        uint256 currentWeek = getCurrentWeek();
        require(buyerWeek[assetIndex_] < currentWeek, "Already updated");

        tidalToken.approve(address(buyer), bonusPerAssetOfB);
        buyer.updateBonus(assetIndex_, bonusPerAssetOfB);

        buyerWeek[assetIndex_] = currentWeek;
    }

    function updateSellerBonus(uint8 category_) external {
        uint256 currentWeek = getCurrentWeek();
        require(sellerWeek[category_] < currentWeek, "Already updated");

        tidalToken.approve(address(seller), bonusPerCategoryOfS);
        seller.updateBonus(category_, bonusPerCategoryOfS);

        sellerWeek[category_] = currentWeek;
    }

    function updateGuarantorBonus(uint256 assetIndex_) external {
        uint256 currentWeek = getCurrentWeek();
        require(guarantorWeek[assetIndex_] < currentWeek, "Already updated");

        tidalToken.approve(address(guarantor), bonusPerAssetOfB);
        guarantor.updateBonus(assetIndex_, bonusPerAssetOfG);

        guarantorWeek[assetIndex_] = currentWeek;
    }
}
