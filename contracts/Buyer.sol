// SPDX-License-Identifier: MIT
pragma solidity 0.6.12;

import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/math/SafeMath.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/SafeERC20.sol";

import "./NonReentrancy.sol";
import "./WeekManaged.sol";

import "./interfaces/IAssetManager.sol";
import "./interfaces/IBuyer.sol";
import "./interfaces/IGuarantor.sol";
import "./interfaces/IPremiumCalculator.sol";
import "./interfaces/IRegistry.sol";
import "./interfaces/ISeller.sol";


// This contract is owned by Timelock.
contract Buyer is IBuyer, Ownable, WeekManaged, NonReentrancy {

    using SafeERC20 for IERC20;
    using SafeMath for uint256;

    IRegistry public registry;

    struct UserInfo {
        uint256 balance;
        uint256 weekBegin;  // The week the coverage begin
        uint256 weekEnd;  // The week the coverage end
        uint256 weekUpdated;  // The week that balance was updated
    }

    mapping(address => UserInfo) public userInfoMap;

    // assetIndex => amount
    mapping(uint16 => uint256) public override currentSubscription;

    // assetIndex => amount
    mapping(uint16 => uint256) public override futureSubscription;

    // assetIndex => utilization
    mapping(uint16 => uint256) public override assetUtilization;

    // assetIndex => total
    mapping(uint16 => uint256) public override premiumForGuarantor;

    // assetIndex => total
    mapping(uint16 => uint256) public override premiumForSeller;

    // Should be claimed immediately in the next week.
    // assetIndex => total
    mapping(uint16 => uint256) public premiumToRefund;

    uint256 public override weekToUpdate;

    // who => assetIndex + 1
    mapping(address => uint16) public buyerAssetIndexPlusOne;

    constructor () public { }

    function setRegistry(IRegistry registry_) external onlyOwner {
        registry = registry_;
    }

    // Set buyer asset index
    function setBuyerAssetIndex(address who_, uint16 assetIndex_) external onlyOwner {
        // No safe math for uint16, but please make sure no overflow.
        buyerAssetIndexPlusOne[who_] = assetIndex_ + 1;
    }

    // Get buyer asset index
    function getBuyerAssetIndex(address who_) public view returns(uint16) {
        require(buyerAssetIndexPlusOne[who_] > 0, "No asset index");
        return buyerAssetIndexPlusOne[who_] - 1;
    }

    // Has buyer asset index
    function hasBuyerAssetIndex(address who_) public view returns(bool) {
        return buyerAssetIndexPlusOne[who_] > 0;
    }

    function getPremiumRate(uint16 assetIndex_) public view returns(uint256) {
        return IPremiumCalculator(registry.premiumCalculator()).getPremiumRate(
            assetIndex_);
    }

    function isUserCovered(address who_) public override view returns(bool) {
        return userInfoMap[who_].weekEnd == getCurrentWeek();
    }

    function getBalance(address who_) public view returns(uint256) {
        return userInfoMap[who_].balance;
    }

    function _refundAndUtilize(uint16 assetIndex_) private {
        uint256 sellerAssetBalance = ISeller(registry.seller()).assetBalance(assetIndex_);

        // Maybe refund to buyer if over-subscribed in the past week, with past premium rate (assetUtilization).
        if (currentSubscription[assetIndex_] > sellerAssetBalance) {
            premiumToRefund[assetIndex_] = currentSubscription[assetIndex_].sub(sellerAssetBalance).mul(
                getPremiumRate(assetIndex_)).div(registry.PREMIUM_BASE());

            // Reduce currentSubscription (not too late).
            currentSubscription[assetIndex_] = sellerAssetBalance;
        }

        // Calculate new assetUtilization from currentSubscription and sellerAssetBalance
        if (sellerAssetBalance == 0) {
            assetUtilization[assetIndex_] = registry.UTILIZATION_BASE();
        } else {
            assetUtilization[assetIndex_] = currentSubscription[assetIndex_] * registry.UTILIZATION_BASE() / sellerAssetBalance;
        }

        // Premium rate also changed.
    }

    // Called every week.
    function beforeUpdate() external lock {
        uint256 currentWeek = getCurrentWeek();

        require(weekToUpdate < currentWeek, "Already called");

        if (weekToUpdate > 0) {
            uint256 totalForGuarantor = 0;
            uint256 totalForSeller = 0;
            uint256 feeForPlatform = 0;

            // To preserve last week's data before update buyers.
            for (uint16 index = 0;
                    index < IAssetManager(registry.assetManager()).getAssetLength();
                    ++index) {
                _refundAndUtilize(index);

                uint256 premiumOfAsset = currentSubscription[index].mul(
                    getPremiumRate(index)).div(registry.PREMIUM_BASE());

                premiumForGuarantor[index] = premiumOfAsset.mul(
                    registry.guarantorPercentage()).div(registry.PERCENTAGE_BASE());
                totalForGuarantor = totalForGuarantor.add(premiumForGuarantor[index]);

                feeForPlatform = feeForPlatform.add(
                    premiumOfAsset.mul(registry.platformPercentage()).div(registry.PERCENTAGE_BASE()));

                premiumForSeller[index] = premiumOfAsset.mul(
                    registry.PERCENTAGE_BASE().sub(registry.guarantorPercentage()).sub(
                        registry.platformPercentage())).div(registry.PERCENTAGE_BASE());
                totalForSeller = totalForSeller.add(premiumForSeller[index]);
            }

            IERC20(registry.baseToken()).safeTransfer(registry.platform(), feeForPlatform);
            IERC20(registry.baseToken()).safeApprove(registry.guarantor(), 0);
            IERC20(registry.baseToken()).safeApprove(registry.guarantor(), totalForGuarantor);
            IERC20(registry.baseToken()).safeApprove(registry.seller(), 0);
            IERC20(registry.baseToken()).safeApprove(registry.seller(), totalForSeller);
        }

        weekToUpdate = currentWeek;
    }

    // Called for every user every week.
    function update(address who_) external {
        uint256 currentWeek = getCurrentWeek();

        require(hasBuyerAssetIndex(who_), "not whitelisted buyer");
        uint16 buyerAssetIndex = getBuyerAssetIndex(who_);

        require(currentWeek == weekToUpdate, "Not ready to update");
        require(userInfoMap[who_].weekUpdated < currentWeek, "Already updated");

        // Get per user premium
        uint256 premium = futureSubscription[buyerAssetIndex].mul(
                getPremiumRate(buyerAssetIndex)).div(registry.PREMIUM_BASE());

        if (userInfoMap[who_].balance >= premium) {
            userInfoMap[who_].balance = userInfoMap[who_].balance.sub(premium);

            if (userInfoMap[who_].weekBegin == 0 ||
                    userInfoMap[who_].weekEnd < userInfoMap[who_].weekUpdated) {
                userInfoMap[who_].weekBegin = currentWeek;
            }

            userInfoMap[who_].weekEnd = currentWeek;

            if (futureSubscription[buyerAssetIndex] > 0) {
                currentSubscription[buyerAssetIndex] = futureSubscription[buyerAssetIndex];
            } else if (currentSubscription[buyerAssetIndex] > 0) {
                currentSubscription[buyerAssetIndex] = 0;
            }
        } else {
            // Stops user's subscription.
            currentSubscription[buyerAssetIndex] = 0;
        }

        userInfoMap[who_].weekUpdated = currentWeek;  // This week.
    }

    // Deposit
    function deposit(uint256 amount_) external lock {
        require(hasBuyerAssetIndex(msg.sender), "not whitelisted buyer");

        IERC20(registry.baseToken()).safeTransferFrom(msg.sender, address(this), amount_);
        userInfoMap[msg.sender].balance = userInfoMap[msg.sender].balance.add(amount_);
    }

    // Withdraw
    function withdraw(uint256 amount_) external lock {
        require(userInfoMap[msg.sender].balance >= amount_, "not enough balance");
        IERC20(registry.baseToken()).safeTransfer(msg.sender, amount_);
        userInfoMap[msg.sender].balance = userInfoMap[msg.sender].balance.sub(amount_);
    }

    function subscribe(uint16 assetIndex_, uint256 amount_) external {
        require(getBuyerAssetIndex(msg.sender) == assetIndex_, "not whitelisted buyer and assetIndex");

        futureSubscription[assetIndex_] = futureSubscription[assetIndex_].add(amount_);
    }

    function unsubscribe(uint16 assetIndex_, uint256 amount_) external {
        require(getBuyerAssetIndex(msg.sender) == assetIndex_, "not whitelisted buyer and assetIndex");

        futureSubscription[assetIndex_] = futureSubscription[assetIndex_].sub(amount_);
    }
}
