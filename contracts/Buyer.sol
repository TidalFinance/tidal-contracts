// SPDX-License-Identifier: MIT
pragma solidity 0.6.12;

import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/math/SafeMath.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/SafeERC20.sol";

import "./common/BaseRelayRecipient.sol";
import "./common/NonReentrancy.sol";
import "./common/WeekManaged.sol";

import "./interfaces/IAssetManager.sol";
import "./interfaces/IBuyer.sol";
import "./interfaces/IGuarantor.sol";
import "./interfaces/IPremiumCalculator.sol";
import "./interfaces/IRegistry.sol";
import "./interfaces/ISeller.sol";


// This contract is owned by Timelock.
contract Buyer is IBuyer, Ownable, WeekManaged, NonReentrancy, BaseRelayRecipient {

    using SafeERC20 for IERC20;
    using SafeMath for uint256;

    string public override versionRecipient = "1.0.0";

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

    event Update(address indexed who_);
    event Deposit(address indexed who_, uint256 amount_);
    event Withdraw(address indexed who_, uint256 amount_);
    event Subscribe(address indexed who_, uint16 indexed assetIndex_, uint256 amount_);
    event Unsubscribe(address indexed who_, uint16 indexed assetIndex_, uint256 amount_);

    constructor (IRegistry registry_) public {
        registry = registry_;
    }

    function _timeExtra() internal override view returns(uint256) {
        return registry.timeExtra();
    }

    function _msgSender() internal override(Context, BaseRelayRecipient) view returns (address payable) {
        return BaseRelayRecipient._msgSender();
    }

    function _trustedForwarder() internal override view returns(address) {
        return registry.trustedForwarder();
    }

    // Set buyer asset index. When 0, it's cleared.
    function setBuyerAssetIndexPlusOne(address who_, uint16 assetIndexPlusOne_) external onlyOwner {
        buyerAssetIndexPlusOne[who_] = assetIndexPlusOne_;
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

    function getBalance(address who_) external view returns(uint256) {
        return userInfoMap[who_].balance;
    }

    function _maybeRefundOverSubscribed(uint16 assetIndex_, uint256 sellerAssetBalance_) private {
        // Maybe refund to buyer if over-subscribed in the past week, with past premium rate (assetUtilization).
        if (currentSubscription[assetIndex_] > sellerAssetBalance_) {
            premiumToRefund[assetIndex_] = currentSubscription[assetIndex_].sub(sellerAssetBalance_).mul(
                getPremiumRate(assetIndex_)).div(registry.PREMIUM_BASE());

            // Reduce currentSubscription (not too late).
            currentSubscription[assetIndex_] = sellerAssetBalance_;
        } else {
            // No need to refund.
            premiumToRefund[assetIndex_] = 0;
        }
    }

    function _calculateAssetUtilization(uint16 assetIndex_, uint256 sellerAssetBalance_) private {
        // Calculate new assetUtilization from currentSubscription and sellerAssetBalance
        if (sellerAssetBalance_ == 0) {
            assetUtilization[assetIndex_] = registry.UTILIZATION_BASE();
        } else {
            assetUtilization[assetIndex_] = currentSubscription[assetIndex_] * registry.UTILIZATION_BASE() / sellerAssetBalance_;
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
                uint256 sellerAssetBalance = ISeller(registry.seller()).assetBalance(index);
                _maybeRefundOverSubscribed(index, sellerAssetBalance);
                _calculateAssetUtilization(index, sellerAssetBalance);

                uint256 premiumOfAsset = currentSubscription[index].mul(
                    getPremiumRate(index)).div(registry.PREMIUM_BASE());

                feeForPlatform = feeForPlatform.add(
                    premiumOfAsset.mul(registry.platformPercentage()).div(registry.PERCENTAGE_BASE()));

                if (IAssetManager(registry.assetManager()).getAssetToken(index) == address(0)) {
                    // When guarantor pool doesn't exist.
                    premiumForGuarantor[index] = 0;
                    premiumForSeller[index] = premiumOfAsset.mul(
                        registry.PERCENTAGE_BASE().sub(
                            registry.platformPercentage())).div(registry.PERCENTAGE_BASE());
                } else {
                    // When guarantor pool exists.
                    premiumForGuarantor[index] = premiumOfAsset.mul(
                        registry.guarantorPercentage()).div(registry.PERCENTAGE_BASE());
                    totalForGuarantor = totalForGuarantor.add(premiumForGuarantor[index]);

                    premiumForSeller[index] = premiumOfAsset.mul(
                        registry.PERCENTAGE_BASE().sub(registry.guarantorPercentage()).sub(
                            registry.platformPercentage())).div(registry.PERCENTAGE_BASE());
                }

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

        // Maybe refund to user.
        userInfoMap[who_].balance = userInfoMap[who_].balance.add(premiumToRefund[buyerAssetIndex]);

        if (ISeller(registry.seller()).isAssetLocked(buyerAssetIndex)) {
            // Stops user's current and future subscription.
            currentSubscription[buyerAssetIndex] = 0;
            futureSubscription[buyerAssetIndex] = 0;
        } else {
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
                // Stops user's current and future subscription.
                currentSubscription[buyerAssetIndex] = 0;
                futureSubscription[buyerAssetIndex] = 0;
            }
        }

        userInfoMap[who_].weekUpdated = currentWeek;  // This week.

        emit Update(who_);
    }

    // Deposit
    function deposit(uint256 amount_) external lock {
        require(hasBuyerAssetIndex(_msgSender()), "not whitelisted buyer");

        IERC20(registry.baseToken()).safeTransferFrom(_msgSender(), address(this), amount_);
        userInfoMap[_msgSender()].balance = userInfoMap[_msgSender()].balance.add(amount_);

        emit Deposit(_msgSender(), amount_);
    }

    // Withdraw
    function withdraw(uint256 amount_) external lock {
        require(userInfoMap[_msgSender()].balance >= amount_, "not enough balance");
        IERC20(registry.baseToken()).safeTransfer(_msgSender(), amount_);
        userInfoMap[_msgSender()].balance = userInfoMap[_msgSender()].balance.sub(amount_);

        emit Withdraw(_msgSender(), amount_);
    }

    function subscribe(uint16 assetIndex_, uint256 amount_) external {
        require(getBuyerAssetIndex(_msgSender()) == assetIndex_, "not whitelisted buyer and assetIndex");

        futureSubscription[assetIndex_] = futureSubscription[assetIndex_].add(amount_);

        emit Subscribe(_msgSender(), assetIndex_, amount_);
    }

    function unsubscribe(uint16 assetIndex_, uint256 amount_) external {
        require(getBuyerAssetIndex(_msgSender()) == assetIndex_, "not whitelisted buyer and assetIndex");

        futureSubscription[assetIndex_] = futureSubscription[assetIndex_].sub(amount_);

        emit Unsubscribe(_msgSender(), assetIndex_, amount_);
    }
}
