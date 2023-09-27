// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {Initializable} from '@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol';
import {EnumerableSet} from '@openzeppelin/contracts/utils/structs/EnumerableSet.sol';
import {ERC721Enumerable} from '@openzeppelin/contracts/token/ERC721/extensions/ERC721Enumerable.sol';
import {ISubscriptionManager} from '../interfaces/ISubscriptionManager.sol';
import {IDatasetNFT} from '../interfaces/IDatasetNFT.sol';

/**
 * @title GenericSingleDatasetSubscriptionManager contract
 * @author Data Tunnel
 * @notice Abstract contract serving as the foundation for managing single Dataset subscriptions and related operations.
 * Derived contracts mint ERC721 tokens that represent subscriptions to the managed Dataset, thus, subscriptions
 * have unique IDs which are the respective minted ERC721 tokens' IDs.
 * @dev Extends ISubscriptionManager, Initializable, ERC721Enumerable
 */
abstract contract GenericSingleDatasetSubscriptionManager is ISubscriptionManager, Initializable, ERC721Enumerable {
  using EnumerableSet for EnumerableSet.AddressSet;
  using EnumerableSet for EnumerableSet.UintSet;

  event SubscriptionPaid(uint256 id, uint256 validSince, uint256 validTill, uint256 paidConsumers);
  event ConsumerAdded(uint256 id, address consumer);
  event ConsumerRemoved(uint256 id, address consumer);

  error UNSUPPORTED_DATASET(uint256 id);
  error CONSUMER_NOT_FOUND(uint256 subscription, address consumer);

  struct SubscriptionDetails {
    uint256 validSince;
    uint256 validTill;
    uint256 paidConsumers;
    EnumerableSet.AddressSet consumers;
  }

  IDatasetNFT public dataset;
  uint256 public datasetId;
  uint256 internal mintCounter;

  mapping(uint256 id => SubscriptionDetails) internal subscriptions;
  mapping(address consumer => EnumerableSet.UintSet subscriptions) internal consumerSubscriptions;

  modifier onlySubscriptionOwner(uint256 subscription) {
    require(ownerOf(subscription) == _msgSender(), 'Not a subscription owner');
    _;
  }

  /**
   * @notice Initialization function
   * @param dataset_ The address of the DatasetNFT contract
   * @param datasetId_ The ID of the Dataset NFT token
   */
  function __GenericSubscriptionManager_init_unchained(address dataset_, uint256 datasetId_) internal onlyInitializing {
    dataset = IDatasetNFT(dataset_);
    datasetId = datasetId_;
  }

  /**
   * @notice Calculates the subscription fee for a given duration (in days) and number of consumers
   * @param durationInDays The duration of the subscription in days
   * @param consumers Number of consumers for the subscription (including owner)
   * @return address The payment token, zero address for native coin
   * @return uint256 The amount to pay
   */
  function calculateFee(uint256 durationInDays, uint256 consumers) internal view virtual returns (address, uint256);

  /**
   * @notice Should charge the subscriber or revert
   * @dev Should call `IDistributionManager.receivePayment()` to distribute the payment
   * @param subscriber Who to charge
   * @param amount Amount to charge
   */
  function charge(address subscriber, uint256 amount) internal virtual;

  /**
   * @notice Verifies if a given subscription is paid for a specified consumer
   * @param ds ID of the Dataset to access (ID of the target Dataset NFT token)
   * @param consumer Address of consumer, signing the data request
   * @return bool True if subscription is paid for `consumer`, false if it is not
   */
  function isSubscriptionPaidFor(uint256 ds, address consumer) external view returns (bool) {
    _requireCorrectDataset(ds);
    EnumerableSet.UintSet storage subscrs = consumerSubscriptions[consumer];
    for (uint256 i; i < subscrs.length(); i++) {
      uint256 sid = subscrs.at(i);
      if (subscriptions[sid].validTill > block.timestamp) return true;
    }
    return false;
  }

  /**
   * @notice Returns a fee for a Dataset subscription with a given duration (in days) and number of consumers
   * @param ds ID of the Dataset to access (ID of the target Dataset NFT token)
   * @param durationInDays The duration of the subscription in days
   * @param consumers Count of consumers who have access to the data using this subscription (including owner)
   * @return token Token used as payment for the subscription, or address(0) for native currency
   * @return amount The fee amount to pay
   */
  function subscriptionFee(
    uint256 ds,
    uint256 durationInDays,
    uint256 consumers
  ) external view returns (address token, uint256 amount) {
    _requireCorrectDataset(ds);
    require(durationInDays > 0 && durationInDays <= 365, 'Invalid subscription duration');
    require(consumers > 0, 'Should be at least 1 consumer');
    return calculateFee(durationInDays, consumers);
  }

  /**
   * @notice Returns a fee for adding new consumers to a specific subscription
   * @param subscription ID of subscription (ID of the minted ERC721 token that represents the subscription)
   * @param extraConsumers Count of new consumers to add
   * @return amount The fee amount
   */
  function extraConsumerFee(uint256 subscription, uint256 extraConsumers) external view returns (uint256 amount) {
    require(extraConsumers > 0, 'Should add at least 1 consumer');
    SubscriptionDetails storage sd = subscriptions[subscription];
    require(sd.validTill > block.timestamp, 'Subcription not valid');
    // (sd.validTill - sd.validSince) was enforced during subscription to be integral multiple of a day in seconds
    uint256 durationInDays_ = (sd.validTill - sd.validSince) / 1 days;
    (, uint256 currentFee) = calculateFee(durationInDays_, sd.paidConsumers);
    (, uint256 newFee) = calculateFee(durationInDays_, sd.paidConsumers + extraConsumers);
    return (newFee > currentFee) ? (newFee - currentFee) : 0;
  }

  /**
   * @notice Subscribes to a Dataset and makes payment
   *
   * @dev Requirements:
   *
   *  - `durationInDays` must be greater than 0 and less than or equal to 365
   *  - `consumers` must be greater than 0
   *
   * Emits a {SubscriptionPaid} and a {Transfer} event.
   *
   * @param ds ID of the Dataset (ID of the target Dataset NFT token)
   * @param durationInDays Duration of the subscription in days
   * @param consumers Count of consumers who have access to the data with this subscription
   * @return sid ID of subscription (ID of the minted ERC721 token that represents the subscription)
   */
  function subscribe(uint256 ds, uint256 durationInDays, uint256 consumers) external payable returns (uint256 sid) {
    return _subscribe(ds, durationInDays, consumers);
  }

  /**
   * @notice Subscribes to a Dataset, makes payment and adds consumers' addresses
   *
   * @dev Requirements:
   *
   *  - `durationInDays` must be greater than 0 and less than or equal to 365
   *  - `consumers` length must be greater than 0
   *
   * Emits a {SubscriptionPaid}, a {Transfer}, and {ConsumerAdded} event(s).
   *
   * @param ds ID of the Dataset (ID of the target Dataset NFT token)
   * @param durationInDays Duration of subscription in days (maximum 365 days)
   * @param consumers Array of consumers who have access to the data with this subscription
   * @return sid ID of subscription (ID of the minted ERC721 token that represents the subscription)
   */
  function subscribeAndAddConsumers(
    uint256 ds,
    uint256 durationInDays,
    address[] calldata consumers
  ) external payable returns (uint256 sid) {
    sid = _subscribe(ds, durationInDays, consumers.length);
    _addConsumers(sid, consumers);
  }

  /**
   * @notice Extends a specific subscription with additional duration (in days) and/or consumers
   * @dev Subscriptions can only be extended duration-wise if remaining duration <= 30 days
   *
   * To extend a subscription only consumer-wise:
   *
   *  - `extraDurationInDays` should be 0
   *  - `extraConsumers` should be greater than 0
   *
   * To extend a subscription only duration-wise:
   *
   *  - `extraDurationInDays` should be greater than 0 and less than or equal to 365
   *  - `extraConsumers` should be 0
   *
   * To extend a subscription both duration-wise and consumer-wise:
   *
   *  -`extraDurationInDays` should be greater than 0 and less than or equal to 365
   *  -`extraConsumers` should be greater than 0
   *
   * Emits a {SubscriptionPaid} event.
   *
   * @param subscription ID of subscription (ID of the minted ERC721 token that represents the subscription)
   * @param extraDurationInDays Days to extend the subscription by
   * @param extraConsumers Number of consumers to add
   */
  function extendSubscription(
    uint256 subscription,
    uint256 extraDurationInDays,
    uint256 extraConsumers
  ) external payable {
    _extendSubscription(subscription, extraDurationInDays, extraConsumers);
  }

  /**
   * @notice Adds the given addresses as consumers of an already existing specified subscription
   * @dev Only callable by the owner of the respective subscription (owner of the ERC721 token that represents the subscription).
   * Emits {ConsumerAdded} event(s).
   * @param subscription ID of subscription (ID of the NFT token that represents the subscription)
   * @param consumers Array of consumers to have access to the data with the specifed subscription
   */
  function addConsumers(
    uint256 subscription,
    address[] calldata consumers
  ) external onlySubscriptionOwner(subscription) {
    _addConsumers(subscription, consumers);
  }

  /**
   * @notice Removes the specified consumers from the set of consumers of the given subscription
   * @dev No refund is paid, but count of consumers is retained.
   * Only callable by the owner of the respective subscription (owner of the ERC721 token that represents the subscription)
   * Emits {ConsumerRemoved} event(s).
   * @param subscription ID of subscription (ID of the NFT token that represents the subscription)
   * @param consumers Array with the addresses of the consumers to remove
   */
  function removeConsumers(
    uint256 subscription,
    address[] calldata consumers
  ) external onlySubscriptionOwner(subscription) {
    _removeConsumers(subscription, consumers);
  }

  /**
   * @notice Replaces a set of old consumers with a same-size set of new consumers for the given subscription
   * @dev Only callable by the owner of the respective subscription (owner of the ERC721 token that represents the subscription).
   * Reverts with `CONSUMER_NOT_FOUND` custom error if `oldConsumers` contains address(es) not present in the subscription's
   * current set of consumers.
   * Emits {ConsumerAdded} and {ConsumerRemoved} event(s).
   * @param subscription ID of subscription (ID of the NFT token that represents the subscription)
   * @param oldConsumers Array containing the addresses of consumers to remove
   * @param newConsumers Array containing the addresses of consumers to add
   */
  function replaceConsumers(
    uint256 subscription,
    address[] calldata oldConsumers,
    address[] calldata newConsumers
  ) external onlySubscriptionOwner(subscription) {
    _replaceConsumers(subscription, oldConsumers, newConsumers);
  }

  /**
   * @notice Internal subscribe function
   * @dev Mints an ERC721 token that represents the creation of the subscription.
   * Called by `subscribe()` and `subscribeAndAddConsumers()`.
   * Emits a {SubscriptionPaid} and a {Transfer} event.
   * @param ds ID of the Dataset to subscribe to (ID of the target Dataset NFT token)
   * @param durationInDays Duration of subscription in days (maximum 365 days)
   * @param consumers Count of consumers to have access to the data with this subscription
   * @return sid ID of subscription (ID of the minted ERC721 token that represents the subscription)
   */
  function _subscribe(uint256 ds, uint256 durationInDays, uint256 consumers) internal returns (uint256 sid) {
    _requireCorrectDataset(ds);
    require(balanceOf(_msgSender()) == 0, 'User already subscribed');
    require(durationInDays > 0 && durationInDays <= 365, 'Invalid subscription duration');

    require(consumers > 0, 'Should be at least 1 consumer');

    (, uint256 fee) = calculateFee(durationInDays, consumers);
    charge(_msgSender(), fee);

    sid = ++mintCounter;
    SubscriptionDetails storage sd = subscriptions[sid];
    sd.validSince = block.timestamp;
    sd.validTill = block.timestamp + (durationInDays * 1 days);
    sd.paidConsumers = consumers;
    _safeMint(_msgSender(), sid);
    emit SubscriptionPaid(sid, sd.validSince, sd.validTill, sd.paidConsumers);
  }

  /**
   * @notice Internal extendSubscription function
   * @dev Subscriptions can only be extended if remaining duration <= 30 days.
   * Called by `extendSubscription()`.
   * Emits a {SubscriptionPaid} event.
   * @param subscription ID of subscription (ID of the minted ERC721 token that represents the subscription)
   * @param extraDurationInDays Days to extend the subscription by
   * @param extraConsumers Number of extra consumers to add
   */
  function _extendSubscription(uint256 subscription, uint256 extraDurationInDays, uint256 extraConsumers) internal {
    _requireMinted(subscription);

    if (extraDurationInDays > 0) require(extraDurationInDays <= 365, 'Invalid extra duration provided');

    SubscriptionDetails storage sd = subscriptions[subscription];
    uint256 newDurationInDays;
    uint256 newValidSince;
    uint256 currentFee;

    if (sd.validTill > block.timestamp) {
      // Subscription is still valid but remaining duration must be <= 30 days to extend it
      if (extraDurationInDays > 0)
        require((sd.validTill - block.timestamp) <= 30 * 1 days, 'Remaining duration > 30 days');

      // (sd.validTill - sd.validSince) was enforced during subscription to be an integral multiple of a day in seconds
      uint256 currentDurationInDays = (sd.validTill - sd.validSince) / 1 days;
      (, currentFee) = calculateFee(currentDurationInDays, sd.paidConsumers);
      newValidSince = sd.validSince;
      newDurationInDays = currentDurationInDays + extraDurationInDays;
    } else {
      // Subscription is already invalid
      // currentFee = 0;
      newValidSince = block.timestamp;
      newDurationInDays = extraDurationInDays;
    }
    uint256 newConsumers = sd.paidConsumers + extraConsumers;
    (, uint256 newFee) = calculateFee(newDurationInDays, newConsumers);
    require(newFee > currentFee, 'Nothing to pay');

    charge(_msgSender(), newFee - currentFee);

    sd.validSince = newValidSince;
    sd.validTill = newValidSince + (newDurationInDays * 1 days);
    sd.paidConsumers = newConsumers;
    emit SubscriptionPaid(subscription, sd.validSince, sd.validTill, sd.paidConsumers);
  }

  /**
   * @notice Internal addConsumers function
   * @dev Called by `addConsumers()` and `subscribeAndAddConsumers()`.
   * Emits {ConsumerAdded} event(s) on condition.
   * @param subscription ID of subscription (ID of the NFT token that represents the subscription)
   * @param consumers Array of consumers to have access to the data with the specifed subscription
   */
  function _addConsumers(uint256 subscription, address[] calldata consumers) internal {
    _requireMinted(subscription);
    SubscriptionDetails storage sd = subscriptions[subscription];
    require(sd.consumers.length() + consumers.length <= sd.paidConsumers, 'Too many consumers to add');
    for (uint256 i; i < consumers.length; i++) {
      address consumer = consumers[i];
      bool added = sd.consumers.add(consumer);
      if (added) {
        consumerSubscriptions[consumer].add(subscription);
        emit ConsumerAdded(subscription, consumer);
      }
    }
  }

  /**
   * @notice Internal removeConsumers function
   * @dev Called by `removeConsumers()`.
   * Emits {ConsumerRemoved} event(s) on condition.
   * @param subscription ID of subscription (ID of the NFT token that represents the subscription)
   * @param consumers Array with the addresses of the consumers to remove
   */
  function _removeConsumers(uint256 subscription, address[] calldata consumers) internal {
    _requireMinted(subscription);
    SubscriptionDetails storage sd = subscriptions[subscription];
    for (uint256 i; i < consumers.length; i++) {
      address consumer = consumers[i];
      bool removed = sd.consumers.remove(consumer);
      if (removed) {
        consumerSubscriptions[consumer].remove(subscription);
        emit ConsumerRemoved(subscription, consumer);
      }
    }
  }

  /**
   * @notice Internal replaceConsumers function
   * @dev Called by `replaceConsumers()`.
   * Emits {ConsumerAdded}, {ConsumerRemoved} event(s) on conditions.
   * @param subscription ID of subscription (ID of the NFT token that represents the subscription)
   * @param oldConsumers Array containing the addresses of consumers to remove
   * @param newConsumers Array containing the addresses of consumers to add
   */
  function _replaceConsumers(
    uint256 subscription,
    address[] calldata oldConsumers,
    address[] calldata newConsumers
  ) internal {
    _requireMinted(subscription);
    SubscriptionDetails storage sd = subscriptions[subscription];
    require(oldConsumers.length == newConsumers.length, 'Array length missmatch');
    for (uint256 i; i < oldConsumers.length; i++) {
      address consumer = oldConsumers[i];
      bool removed = sd.consumers.remove(consumer);
      if (removed) {
        consumerSubscriptions[consumer].remove(subscription);
        emit ConsumerRemoved(subscription, consumer);
      } else {
        // Should revert because otherwise we can exeed paidConsumers limit
        revert CONSUMER_NOT_FOUND(subscription, consumer);
      }
      consumer = newConsumers[i];
      bool added = sd.consumers.add(consumer);
      if (added) {
        consumerSubscriptions[consumer].add(subscription);
        emit ConsumerAdded(subscription, consumer);
      }
    }
  }

  /**
   * @notice Reverts with `UNSUPPORTED_DATASET` custom error if `_datasetId` is not the ID of the managed Dataset
   * @dev The ID of the managed dataset is set at `__GenericSubscriptionManager_init_unchained()`
   * @param _datasetId The ID to check
   */
  function _requireCorrectDataset(uint256 _datasetId) internal view {
    if (datasetId != _datasetId) revert UNSUPPORTED_DATASET(_datasetId);
  }
}
