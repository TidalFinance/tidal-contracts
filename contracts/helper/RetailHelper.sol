// SPDX-License-Identifier: MIT
pragma solidity 0.6.12;

import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/math/SafeMath.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/SafeERC20.sol";

import "../common/BaseRelayRecipient.sol";
import "../common/Migratable.sol";
import "../common/NonReentrancy.sol";

import "../interfaces/IAssetManager.sol";
import "../interfaces/IBuyer.sol";
import "../interfaces/IRegistry.sol";
import "../interfaces/ISeller.sol";

interface IRetailPremiumCalculator {
    function getPremiumRate(uint16 assetIndex_, address who_) external view returns(uint256);
}

contract RetailHelper is Ownable, NonReentrancy, BaseRelayRecipient, Migratable {

    using SafeERC20 for IERC20;
    using SafeMath for uint256;

    string public override versionRecipient = "1.0.0";

    uint256 public constant PRICE_BASE = 1e18;
    uint256 public constant RATIO_BASE = 1e18;

    IRegistry public registry;
    IRetailPremiumCalculator public retailPremiumCalculator;

    mapping(address => bool) public updaterMap;

    modifier onlyUpdater() {
        require(updaterMap[msg.sender], "The caller does not have updater role privileges");
        _;
    }

    struct UserInfo {
        uint256 balanceBase;
        uint256 balanceAsset;
        uint256 premiumBase;
        uint256 premiumAsset;

        uint256 weekUpdated;  // The week that UserInfo was updated
    }

    mapping(uint16 => mapping(address => UserInfo)) public userInfoMap;

    struct AssetInfo {
        // The token address here is supposed to be the same as the token adress
        // in assetManager. However we don't use the one in assetManager because
        // sometimes we don't want to setup guarantor for certain assets but do
        // allow them to use ResellHelper.
        address token;
        address recipient;

        uint256 futureCapacityOffset;
        uint256 futureTokenPrice;
        uint256 capacityOffset;
        uint256 tokenPrice;

        uint256 subscriptionRatio;

        uint256 weekUpdated;  // The week that AssetInfo was updated
    }

    mapping(uint16 => AssetInfo) public assetInfoMap;

    struct Subscription {
        uint256 currentBase;
        uint256 currentAsset;
        uint256 futureBase;
        uint256 futureAsset;
    }

    mapping(uint16 => Subscription) public subscriptionByAsset;
    mapping(uint16 => mapping(address => Subscription)) public subscriptionByUser;

    event ChangeCapacityOffset(address indexed who_, uint16 indexed assetIndex_, uint256 capacityOffset_);
    event ChangeTokenPrice(address indexed who_, uint16 indexed assetIndex_, uint256 tokenPrice_);
    event UpdateAsset(uint16 indexed assetIndex_);
    event UpdateUser(address indexed who_, uint16 indexed assetIndex_);
    event DepositBase(address indexed who_, uint16 indexed assetIndex_, uint256 amount_);
    event DepositAsset(address indexed who_, uint16 indexed assetIndex_, uint256 amount_);
    event WithdrawBase(address indexed who_, uint16 indexed assetIndex_, uint256 amount_);
    event WithdrawAsset(address indexed who_, uint16 indexed assetIndex_, uint256 amount_);
    event AdjustSubscriptionBase(address indexed who_, uint16 indexed assetIndex_, uint256 amoun_);
    event AdjustSubscriptionAsset(address indexed who_, uint16 indexed assetIndex_, uint256 amount_);

    constructor (IRegistry registry_) public {
        registry = registry_;
    }

    function _msgSender() internal override(Context, BaseRelayRecipient) view returns (address payable) {
        return BaseRelayRecipient._msgSender();
    }

    function _trustedForwarder() internal override view returns(address) {
        return registry.trustedForwarder();
    }

    function _migrationCaller() internal override view returns(address) {
        return owner();
    }

    function migrate(uint16 assetIndex_) external lock {
        require(address(migrateTo) != address(0), "Destination not set");

        AssetInfo storage assetInfo = assetInfoMap[assetIndex_];
        UserInfo storage userInfo = userInfoMap[assetIndex_][_msgSender()];

        require(userInfo.balanceBase > 0 || userInfo.balanceAsset > 0, "Empty account");

        if (userInfo.balanceBase > 0) {
          IERC20(registry.baseToken()).safeTransfer(address(migrateTo), userInfo.balanceBase);
          migrateTo.onMigration(_msgSender(), userInfo.balanceBase, abi.encodePacked(assetIndex_, true));
          userInfo.balanceBase = 0;
        }

        if (userInfo.balanceAsset > 0 && assetInfo.token != address(0)) {
          IERC20(assetInfo.token).safeTransfer(address(migrateTo), userInfo.balanceAsset);
          migrateTo.onMigration(_msgSender(), userInfo.balanceAsset, abi.encodePacked(assetIndex_, false));
          userInfo.balanceAsset = 0;
        }
    }

    function setUpdater(address _who, bool _isUpdater) external onlyOwner {
        updaterMap[_who] = _isUpdater;
    }

    function setRetailPremiumCalculator(IRetailPremiumCalculator retailPremiumCalculator_) external onlyOwner {
        retailPremiumCalculator = retailPremiumCalculator_;
    }

    function setAssetInfo(
        uint16 assetIndex_,
        address token_,
        address recipient_,
        uint256 capacityOffset_
    ) external onlyOwner {
        require(recipient_ != address(0), "recipient_ is zero");
        // token_ can be zero, and capacityOffset_ can be zero too.

        assetInfoMap[assetIndex_].token = token_;
        assetInfoMap[assetIndex_].recipient = recipient_;
        assetInfoMap[assetIndex_].capacityOffset = capacityOffset_;
    }

    function changeCapacityOffset(
        uint16 assetIndex_,
        uint256 capacityOffset_
    ) external {
        require(_msgSender() == assetInfoMap[assetIndex_].recipient, 
                "Only recipient can change");

        assetInfoMap[assetIndex_].futureCapacityOffset = capacityOffset_;

        emit ChangeCapacityOffset(_msgSender(), assetIndex_, capacityOffset_);
    }

    function changeTokenPrice(
        uint16 assetIndex_,
        uint256 tokenPrice_
    ) external onlyUpdater {
        assetInfoMap[assetIndex_].futureTokenPrice = tokenPrice_;

        emit ChangeTokenPrice(_msgSender(), assetIndex_, tokenPrice_);
    }

    function getCurrentWeek() public view returns(uint256) {
        return (now + (4 days)) / (7 days);  // 4 days is the offset.
    }

    function getPremiumRate(uint16 assetIndex_, address who_) public view returns(uint256) {
        return IRetailPremiumCalculator(retailPremiumCalculator).getPremiumRate(assetIndex_, who_);
    }

    function getEffectiveCapacity(uint16 assetIndex_) public view returns(uint256) {
        AssetInfo storage assetInfo = assetInfoMap[assetIndex_];
        uint256 sellerAssetBalance = ISeller(registry.seller()).assetBalance(assetIndex_);
        uint256 buyerSubscription = IBuyer(registry.buyer()).currentSubscription(assetIndex_);
        uint256 allCapacity = sellerAssetBalance < buyerSubscription ? sellerAssetBalance : buyerSubscription;

        if (allCapacity <= assetInfo.capacityOffset) {
            return 0;
        } else {
            return allCapacity.sub(assetInfo.capacityOffset);
        }
    }

    // Step 1.
    function updateAsset(uint16 assetIndex_) external lock onlyUpdater {
        uint256 currentWeek = getCurrentWeek();

        AssetInfo storage assetInfo = assetInfoMap[assetIndex_];

        require(assetInfo.recipient != address(0), "Recipient is zero");
        require(assetInfo.weekUpdated < currentWeek, "Already called");

        // Uses future configurations.
        assetInfo.capacityOffset = assetInfo.futureCapacityOffset;
        assetInfo.tokenPrice = assetInfo.futureTokenPrice;

        Subscription storage subscription = subscriptionByAsset[assetIndex_];

        uint256 actualSubscription = subscription.futureBase.add(
            subscription.futureAsset.mul(assetInfo.tokenPrice).div(PRICE_BASE));

        uint256 effectiveCapacity = getEffectiveCapacity(assetIndex_);

        if (actualSubscription > effectiveCapacity) {
            subscription.futureBase = subscription.futureBase.mul(
                effectiveCapacity).div(actualSubscription);
            subscription.futureAsset = subscription.futureAsset.mul(
                effectiveCapacity).div(actualSubscription);

            assetInfo.subscriptionRatio = effectiveCapacity.mul(RATIO_BASE).div(actualSubscription);
        } else {
            assetInfo.subscriptionRatio = RATIO_BASE;
        }

        subscription.currentBase = subscription.futureBase;
        subscription.currentAsset = subscription.futureAsset;

        assetInfoMap[assetIndex_].weekUpdated = currentWeek;  // This week.

        emit UpdateAsset(assetIndex_);
    }

    function _getPremiumBase(uint16 assetIndex_, address who_) private view returns(uint256) {
        AssetInfo storage assetInfo = assetInfoMap[assetIndex_];
        Subscription storage subscription = subscriptionByUser[assetIndex_][who_];

        return subscription.futureBase.mul(
            getPremiumRate(assetIndex_, who_)).div(
                registry.PREMIUM_BASE()).mul(
                    assetInfo.subscriptionRatio) / RATIO_BASE;
        // HACK: '/' instead of .div to prevent "Stack too deep" error.
    }

    function _getPremiumAsset(uint16 assetIndex_, address who_) private view returns(uint256) {
        AssetInfo storage assetInfo = assetInfoMap[assetIndex_];
        Subscription storage subscription = subscriptionByUser[assetIndex_][who_];

        return subscription.futureAsset.mul(
            getPremiumRate(assetIndex_, who_)).div(
                registry.PREMIUM_BASE()).mul(
                    PRICE_BASE).div(
                        assetInfo.tokenPrice).mul(
                            assetInfo.subscriptionRatio) / RATIO_BASE;
        // HACK: '/' instead of .div to prevent "Stack too deep" error.
    }

    // Step 2.
    function updateUser(address who_, uint16 assetIndex_) external lock onlyUpdater {
        require(who_ != address(0), "who_ is zero");

        uint256 currentWeek = getCurrentWeek();

        AssetInfo storage assetInfo = assetInfoMap[assetIndex_];
        UserInfo storage userInfo = userInfoMap[assetIndex_][who_];
        Subscription storage subscription = subscriptionByUser[assetIndex_][who_];

        require(assetInfo.recipient != address(0), "Recipient is zero");
        require(assetInfo.weekUpdated == currentWeek, "updateAsset first");
        require(userInfo.weekUpdated < currentWeek, "Already called");

        // Maybe deduct premium as base.
        uint256 premiumBase = _getPremiumBase(assetIndex_, who_);

        if (userInfo.balanceBase >= premiumBase) {
            userInfo.balanceBase = userInfo.balanceBase.sub(premiumBase);
            userInfo.premiumBase = premiumBase;

            subscription.futureBase = subscription.futureBase.mul(
                assetInfo.subscriptionRatio).div(RATIO_BASE);

            IERC20(registry.baseToken()).safeTransfer(assetInfo.recipient, premiumBase);
        } else {
            userInfo.premiumBase = 0;
            subscription.futureBase = 0;
        }

        // Maybe deduct premium as asset.
        if (assetInfo.token != address(0)) {
            require(assetInfo.tokenPrice > 0, "Price is zero");

            uint256 premiumAsset = _getPremiumAsset(assetIndex_, who_);
            if (userInfo.balanceAsset >= premiumAsset) {
                userInfo.balanceAsset = userInfo.balanceAsset.sub(premiumAsset);
                userInfo.premiumAsset = premiumAsset;

                subscription.futureAsset = subscription.futureAsset.mul(
                    assetInfo.subscriptionRatio).div(RATIO_BASE);

                IERC20(assetInfo.token).safeTransfer(assetInfo.recipient, premiumAsset);
            } else {
                userInfo.premiumAsset = 0;
                subscription.futureAsset = 0;
            }
        }

        subscription.currentBase = subscription.futureBase;
        subscription.currentAsset = subscription.futureAsset;

        userInfo.weekUpdated = currentWeek;  // This week.

        emit UpdateUser(who_, assetIndex_);
    }

    function depositBase(uint16 assetIndex_, uint256 amount_) external lock {
        AssetInfo storage assetInfo = assetInfoMap[assetIndex_];
        UserInfo storage userInfo = userInfoMap[assetIndex_][_msgSender()];

        require(amount_ > 0, "amount_ is zero");
        require(assetInfo.recipient != address(0), "Recipient is zero");
        require(userInfo.weekUpdated == getCurrentWeek() || userInfo.weekUpdated == 0,
                "User not updated yet");

        IERC20(registry.baseToken()).safeTransferFrom(_msgSender(), address(this), amount_);
        userInfo.balanceBase = userInfo.balanceBase.add(amount_);

        emit DepositBase(_msgSender(), assetIndex_, amount_);
    }

    function depositAsset(uint16 assetIndex_, uint256 amount_) external lock {
        AssetInfo storage assetInfo = assetInfoMap[assetIndex_];
        UserInfo storage userInfo = userInfoMap[assetIndex_][_msgSender()];

        require(amount_ > 0, "amount_ is zero");
        require(assetInfo.token != address(0), "token is zero");
        require(assetInfo.recipient != address(0), "Recipient is zero");

        IERC20(assetInfo.token).safeTransferFrom(
            _msgSender(), address(this), amount_);
        userInfo.balanceAsset = userInfo.balanceAsset.add(amount_);

        emit DepositAsset(_msgSender(), assetIndex_, amount_);
    }

    function withdrawBase(uint16 assetIndex_, uint256 amount_) external lock {
        AssetInfo storage assetInfo = assetInfoMap[assetIndex_];
        UserInfo storage userInfo = userInfoMap[assetIndex_][_msgSender()];

        require(amount_ > 0, "amount_ is zero");
        require(assetInfo.recipient != address(0), "Recipient is zero");
        require(userInfo.balanceBase >= amount_, "not enough balance");

        IERC20(registry.baseToken()).safeTransfer(_msgSender(), amount_);
        userInfo.balanceBase = userInfo.balanceBase.sub(amount_);

        emit WithdrawBase(_msgSender(), assetIndex_, amount_);
    }

    function withdrawAsset(uint16 assetIndex_, uint256 amount_) external lock {
        AssetInfo storage assetInfo = assetInfoMap[assetIndex_];
        UserInfo storage userInfo = userInfoMap[assetIndex_][_msgSender()];

        require(amount_ > 0, "amount_ is zero");
        require(assetInfo.token != address(0), "token is zero");
        require(assetInfo.recipient != address(0), "Recipient is zero");
        require(userInfo.balanceAsset >= amount_, "not enough balance");

        IERC20(assetInfo.token).safeTransfer(_msgSender(), amount_);
        userInfo.balanceAsset = userInfo.balanceAsset.sub(amount_);

        emit WithdrawAsset(_msgSender(), assetIndex_, amount_);
    }

    function adjustSubscriptionBase(uint16 assetIndex_, uint256 amount_) external {
        AssetInfo storage assetInfo = assetInfoMap[assetIndex_];

        require(assetInfo.recipient != address(0), "Recipient is zero");

        subscriptionByAsset[assetIndex_].futureBase =
            subscriptionByAsset[assetIndex_].futureBase.add(
                amount_).sub(
                    subscriptionByUser[assetIndex_][_msgSender()].futureBase);
        subscriptionByUser[assetIndex_][_msgSender()].futureBase = amount_;
        emit AdjustSubscriptionBase(_msgSender(), assetIndex_, amount_);
    }

    function adjustSubscriptionAsset(uint16 assetIndex_, uint256 amount_) external {
        AssetInfo storage assetInfo = assetInfoMap[assetIndex_];

        require(assetInfo.token != address(0), "token is zero");
        require(assetInfo.recipient != address(0), "Recipient is zero");

        subscriptionByAsset[assetIndex_].futureAsset =
            subscriptionByAsset[assetIndex_].futureAsset.add(
                amount_).sub(
                    subscriptionByUser[assetIndex_][_msgSender()].futureAsset);
        subscriptionByUser[assetIndex_][_msgSender()].futureAsset = amount_;
        emit AdjustSubscriptionAsset(_msgSender(), assetIndex_, amount_);
    }
}
