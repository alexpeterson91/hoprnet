// SPDX-License-Identifier: GPL-3.0-only

pragma solidity ^0.8.0;

import '@openzeppelin/contracts/token/ERC20/IERC20.sol';
import '@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol';
import '@openzeppelin/contracts/token/ERC777/IERC777Recipient.sol';
import '@openzeppelin/contracts/token/ERC721/IERC721Receiver.sol';
import '@openzeppelin/contracts/security/ReentrancyGuard.sol';
import '@openzeppelin/contracts/access/Ownable.sol';
import '@openzeppelin/contracts/utils/introspection/IERC1820Registry.sol';
import '@openzeppelin/contracts/utils/math/Math.sol';
import './IHoprBoost.sol';

/**
 * @dev Create a base contract for HOPR's staking program.
 * New season can inherit this contract to reduce work for testing.
 */
contract HoprStakeBase is Ownable, IERC777Recipient, IERC721Receiver, ReentrancyGuard {
  using SafeERC20 for IERC20;
  using Math for uint256;

  struct Account {
    uint256 actualLockedTokenAmount; // The amount of LOCK_TOKEN being actually locked to the contract.
    // Those tokens can be withdrawn after “UNLOCK_START”
    uint256 lastSyncTimestamp; // Timestamp at which any “Account” attribute gets synced for the last time.
    uint256 cumulatedRewards; // Rewards accredited to the account at “lastSyncTimestamp”.
    uint256 claimedRewards; // Rewards claimed by the account.
  }

  // public constants
  uint256 public constant FACTOR_DENOMINATOR = 1e12; // Denominator of the “Basic reward factor”. Default value is 1e12.

  address public LOCK_TOKEN = 0xD057604A14982FE8D88c5fC25Aac3267eA142a08; // Token that HOPR holders need to lock to the contract: xHOPR address. Default value: HOPR on xdai
  address public REWARD_TOKEN = 0xD4fdec44DB9D44B8f2b6d529620f9C0C7066A2c1; // Token that HOPR holders can claim as rewards: wxHOPR address Default value: wxHOPR
  IHoprBoost public NFT_CONTRACT = IHoprBoost(0x43d13D7B83607F14335cF2cB75E87dA369D056c7); // Address of the HoprBoost NFT smart contract. Default value: HoprBoost

  // immutable variables defined in the constructor
  uint256 public immutable PROGRAM_START; // Block timestamp at which incentive program starts.
  uint256 public immutable PROGRAM_END; // Block timestamp at which incentive program ends. From this timestamp on, tokens can be unlocked.
  uint256 public immutable BASIC_FACTOR_NUMERATOR; // Numerator of the “Basic reward factor”, for all accounts that participate in the program. Reward rate is BASIC_FACTOR_NUMERATOR/FACTOR_DENOMINATOR per second.
  uint256 public immutable BOOST_CAP; // Cap on actual locked tokens for receiving additional boosts, in LOCK_TOKEN's decimals (1e18)

  mapping(address => mapping(uint256 => uint256)) public redeemedNft; // Redeemed NFT per account, structured as “account -> index -> NFT tokenId”.
  mapping(address => uint256) public redeemedNftIndex; // The last index of redeemed NFT of an account. It defines the length of the “redeemedBoostToken mapping.
  mapping(address => mapping(uint256 => uint256)) public redeemedFactor; // Redeemed boost factor per account, structured as “account -> index -> NFT tokenId”.
  mapping(address => uint256) public redeemedFactorIndex; // The last index of redeemed boost factor factor of an account. It defines the length of the “redeemedFactor” mapping.
  mapping(uint256 => bool) public isBlockedNft; // Type index of HoprBoost NFT that is not accepted in this season

  mapping(address => Account) public accounts; // It stores the locked token amount, earned and claimed rewards per account.
  uint256 public totalLocked; // Total amount of tokens being locked in the incentive program.
  uint256 public availableReward; // Total amount of reward tokens currently available in the lock.

  // setup ERC1820
  IERC1820Registry private constant ERC1820_REGISTRY = IERC1820Registry(0x1820a4B7618BdE71Dce8cdc73aAB6C95905faD24);
  bytes32 private constant TOKENS_RECIPIENT_INTERFACE_HASH = keccak256('ERC777TokensRecipient');

  event Sync(address indexed account, uint256 indexed increment);
  event Staked(address indexed account, uint256 indexed actualAmount);
  event Released(address indexed account, uint256 indexed actualAmount);
  event RewardFueled(uint256 indexed amount);
  event Redeemed(address indexed account, uint256 indexed boostTokenId, bool indexed factorRegistered);
  event Claimed(address indexed account, uint256 indexed rewardAmount);
  event NftBlocked(uint256 indexed typeIndex);
  event NftAllowed(uint256 indexed typeIndex);

  /**
   * @dev Provide basic parameters for the new staking season.
   * Transfer owner role to the new owner address.
   * At deployment, it also registers the staking contract as an ERC777 recipient.
   * @param _newOwner address Address of the new owner. This new owner can reclaim any ERC20 and ERC721 token being accidentally sent to the lock contract.
   * @param _programStart uint256 Timestamp from which the new staking season starts.
   * @param _programEnd uint256 Timestamp till which the new staking season ends.
   * @param _basicFactorNumerator uint256 Mumerator for the basic APY.
   * @param _boostCap uint256 Cap for staked tokens to enjoy extra boost
   * @param _nftAddress address Address of the NFT contract.
   * @param _lockToken address Address of the stake token xHOPR.
   * @param _rewardToken address Address of the reward token wxHOPR.
   */
  constructor(
    address _newOwner,
    uint256 _programStart,
    uint256 _programEnd,
    uint256 _basicFactorNumerator,
    uint256 _boostCap,
    address _nftAddress,
    address _lockToken,
    address _rewardToken
  ) {
    // set program parameters
    PROGRAM_START = _programStart;
    PROGRAM_END = _programEnd;
    BASIC_FACTOR_NUMERATOR = _basicFactorNumerator;
    BOOST_CAP = _boostCap;
    transferOwnership(_newOwner);
    ERC1820_REGISTRY.setInterfaceImplementer(address(this), TOKENS_RECIPIENT_INTERFACE_HASH, address(this));
    // remove this condition as the staging environment is with Gnosis
    LOCK_TOKEN = _lockToken;
    REWARD_TOKEN = _rewardToken;
    NFT_CONTRACT = IHoprBoost(_nftAddress);
  }

  /**
   * @dev Given NFT name type and rank name (as in HoprBoost) returns if the hodler has redeemed such an NFT
   * @param nftType string Type name of the HoprBoost NFT.
   * @param nftRank string Rank name of the HoprBoost NFT.
   * @param hodler address Address of an account that stakes xHOPR tokens and/or redeems its HoprBoost NFT.
   */
  function isNftTypeAndRankRedeemed1(
    string memory nftType,
    string memory nftRank,
    address hodler
  ) external view returns (bool) {
    string memory nftURI = string(abi.encodePacked(nftType, '/', nftRank));

    // compare `boostType/boosRank` of redeemed NFTs with `nftURI`
    for (uint256 index = 0; index < redeemedNftIndex[hodler]; index++) {
      uint256 redeemedTokenId = redeemedNft[hodler][index];
      string memory redeemedTokenURI = NFT_CONTRACT.tokenURI(redeemedTokenId);
      if (_hasSubstring(redeemedTokenURI, nftURI)) {
        return true;
      }
    }
    return false;
  }

  /**
   * @dev Given NFT type index and rank name (as in HoprBoost) returns if the hodler has redeemed such an NFT
   * @param nftTypeIndex uint256 Type index of the HoprBoost NFT.
   * @param nftRank string Rank name of the HoprBoost NFT.
   * @param hodler address Address of an account that stakes xHOPR tokens and/or redeems its HoprBoost NFT.
   */
  function isNftTypeAndRankRedeemed2(
    uint256 nftTypeIndex,
    string memory nftRank,
    address hodler
  ) external view returns (bool) {
    // compare `boostType/boosRank` of redeemed NFTs with `nftURI`
    for (uint256 index = 0; index < redeemedNftIndex[hodler]; index++) {
      uint256 redeemedTokenId = redeemedNft[hodler][index];
      string memory redeemedTokenURI = NFT_CONTRACT.tokenURI(redeemedTokenId);
      if (NFT_CONTRACT.typeIndexOf(redeemedTokenId) == nftTypeIndex && _hasSubstring(redeemedTokenURI, nftRank)) {
        return true;
      }
    }
    return false;
  }

  /**
   * @dev Given NFT type index and the boost numerator (as in HoprBoost) returns if the hodler has redeemed such an NFT
   * @param nftTypeIndex uint256 Type index of the HoprBoost NFT.
   * @param boostNumerator uint256 Boost numerator of the HoprBoost NFT.
   * @param hodler address Address of an account that stakes xHOPR tokens and/or redeems its HoprBoost NFT.
   */
  function isNftTypeAndRankRedeemed3(
    uint256 nftTypeIndex,
    uint256 boostNumerator,
    address hodler
  ) external view returns (bool) {
    for (uint256 index = 0; index < redeemedNftIndex[hodler]; index++) {
      uint256 redeemedTokenId = redeemedNft[hodler][index];
      (uint256 redeemedBoost, ) = NFT_CONTRACT.boostOf(redeemedTokenId);
      if (NFT_CONTRACT.typeIndexOf(redeemedTokenId) == nftTypeIndex && boostNumerator == redeemedBoost) {
        return true;
      }
    }
    return false;
  }

  /**
   * @dev Given NFT type name and the boost numerator (as in HoprBoost) returns if the hodler has redeemed such an NFT
   * @param nftType string Type name of the HoprBoost NFT.
   * @param boostNumerator uint256 Boost numerator of the HoprBoost NFT.
   * @param hodler address Address of an account that stakes xHOPR tokens and/or redeems its HoprBoost NFT.
   */
  function isNftTypeAndRankRedeemed4(
    string memory nftType,
    uint256 boostNumerator,
    address hodler
  ) external view returns (bool) {
    for (uint256 index = 0; index < redeemedNftIndex[hodler]; index++) {
      uint256 redeemedTokenId = redeemedNft[hodler][index];
      (uint256 redeemedBoost, ) = NFT_CONTRACT.boostOf(redeemedTokenId);
      if (
        keccak256((bytes(NFT_CONTRACT.typeOf(redeemedTokenId)))) == keccak256((bytes(nftType))) &&
        boostNumerator == redeemedBoost
      ) {
        return true;
      }
    }
    return false;
  }

  /**
   * @dev Owner can block NFTs from being redeemed in the current staking contract by its type name (as in HoprBoost)
   * @param typeIndex integer Type index to be blocked
   */
  function ownerBlockNftType(uint256 typeIndex) external onlyOwner {
    require(!isBlockedNft[typeIndex], 'HoprStake: NFT type is already blocked');
    _ownerBlockNftType(typeIndex);
  }

  /**
   * @dev Owner can allow blocked NFTs to be redeemable.
   * @param typeIndex integer Type index to be allowed
   */
  function ownerUnblockNftType(uint256 typeIndex) external onlyOwner {
    require(isBlockedNft[typeIndex], 'HoprStake: NFT type is not blocked');
    isBlockedNft[typeIndex] = false;
    emit NftAllowed(typeIndex);
  }

  /**
   * @dev ERC677 hook. Token holders can send their tokens with `transferAndCall` to the stake contract.
   * After PROGRAM_END, it refuses tokens; Before PROGRAM_END, it accepts tokens xHOPR token, sync
   * Account state, and update totalLocked.
   * @param _from address Address of tokens sender
   * @param _value uint256 token amount being transferred
   * @param _data bytes Data being sent along with token transfer
   */
  function onTokenTransfer(
    address _from,
    uint256 _value,
    bytes memory _data
  ) external returns (bool) {
    require(msg.sender == LOCK_TOKEN, 'HoprStake: Only accept LOCK_TOKEN in staking');
    require(block.timestamp <= PROGRAM_END, 'HoprStake: Program ended, cannot stake anymore.');

    _sync(_from);
    accounts[_from].actualLockedTokenAmount += _value;
    totalLocked += _value;
    emit Staked(_from, _value);

    return true;
  }

  /**
   * @dev ERC777 hook. To receive wxHOPR to fuel the reward pool with `send()` method. It updates the availableReward by tokenAmount.
   * @param operator address operator requesting the transfer
   * @param from address token holder address
   * @param to address recipient address
   * @param amount uint256 amount of tokens to transfer
   * @param userData bytes hex information provided by the token holder (if any)
   * @param operatorData bytes extra information provided by the operator (if any)
   */
  function tokensReceived(
    address operator,
    address from,
    address to,
    uint256 amount,
    bytes calldata userData,
    bytes calldata operatorData
  ) external override {
    require(msg.sender == REWARD_TOKEN, 'HoprStake: Sender must be wxHOPR token');
    require(to == address(this), 'HoprStake: Must be sending tokens to HoprStake contract');
    require(from == owner(), 'HoprStake: Only accept owner to provide rewards');
    availableReward += amount;
    emit RewardFueled(amount);
  }

  /**
   * @dev Whenever a boost `tokenId` token is transferred to this contract via {IERC721-safeTransferFrom}
   * when redeeming, this function is called. Boost factor associated with the
   * It must return its Solidity selector to confirm the token transfer upon success.
   * @param operator address operator requesting the transfer
   * @param from address token holder address
   * @param tokenId uint256 amount of tokens to transfer
   * @param data bytes hex information provided by the token holder (if any)
   */
  function onERC721Received(
    address operator,
    address from,
    uint256 tokenId,
    bytes calldata data
  ) external override returns (bytes4) {
    require(_msgSender() == address(NFT_CONTRACT), 'HoprStake: Cannot SafeTransferFrom tokens other than HoprBoost.');
    require(block.timestamp <= PROGRAM_END, 'HoprStake: Program ended, cannot redeem boosts.');
    // Account memory account = accounts[from];
    _sync(from);

    // redeem NFT
    redeemedNft[from][redeemedNftIndex[from]] = tokenId;
    redeemedNftIndex[from] += 1;

    // update boost factor
    uint256 typeId = NFT_CONTRACT.typeIndexOf(tokenId);
    (uint256 factor, ) = NFT_CONTRACT.boostOf(tokenId);
    require(!isBlockedNft[typeId], 'HoprStake: Can only redeem NFTs of allowed types.');

    uint256 boostIndex = redeemedFactorIndex[from];
    uint256 index = 0;
    for (index; index < boostIndex; index++) {
      // loop through redeemed factors, replace the factor of the same type, if the current factor is larger.
      uint256 redeemedId = redeemedFactor[from][index];
      uint256 redeemedIndex = NFT_CONTRACT.typeIndexOf(redeemedId);
      (uint256 redeemedFactorValue, ) = NFT_CONTRACT.boostOf(redeemedId);

      if (redeemedIndex == typeId) {
        if (redeemedFactorValue < factor) {
          redeemedFactor[from][index] = tokenId;
        }
        emit Redeemed(from, tokenId, redeemedFactorValue < factor);
        break;
      }
    }
    if (index == boostIndex) {
      // new type being redeemed.
      redeemedFactor[from][boostIndex] = tokenId;
      redeemedFactorIndex[from] += 1;
      emit Redeemed(from, tokenId, true);
    }

    return IERC721Receiver(address(this)).onERC721Received.selector;
  }

  /**
   * @dev Manually sync account's reward states
   * @notice public function of ``_sync``.
   * @param account address Account whose stake rewards will be synced.
   */
  function sync(address account) external {
    _sync(account);
  }

  /**
   * @dev Sync rewards and claim them
   * @notice public function of ``_sync`` + ``_claim``
   * @param account address Account whose stake rewards will be synced and claimed.
   */
  function claimRewards(address account) external {
    _sync(account);
    _claim(account);
  }

  /**
   * @dev Unlock staking for caller
   */
  function unlock() external {
    _unlockFor(msg.sender);
  }

  /**
   * @dev Unlock staking for a given account
   * @param account address Account that staked tokens.
   */
  function unlockFor(address account) external {
    _unlockFor(account);
  }

  /**
   * @dev Reclaim any ERC20 token being accidentally sent to the contract.
   * @param tokenAddress address ERC20 token address.
   */
  function reclaimErc20Tokens(address tokenAddress) external onlyOwner nonReentrant {
    uint256 difference;
    if (tokenAddress == LOCK_TOKEN) {
      difference = IERC20(LOCK_TOKEN).balanceOf(address(this)) - totalLocked;
    } else {
      difference = IERC20(tokenAddress).balanceOf(address(this));
    }
    IERC20(tokenAddress).safeTransfer(owner(), difference);
  }

  /**
   * @dev Reclaim any ERC721 token being accidentally sent to the contract.
   * @param tokenAddress address ERC721 token address.
   */
  function reclaimErc721Tokens(address tokenAddress, uint256 tokenId) external onlyOwner nonReentrant {
    require(tokenAddress != address(NFT_CONTRACT), 'HoprStake: Cannot claim HoprBoost NFT');
    IHoprBoost(tokenAddress).transferFrom(address(this), owner(), tokenId);
  }

  /**
   * @dev Shortcut that returns the actual stake of an account.
   * @param _account address Address of the staker account.
   */
  function stakedHoprTokens(address _account) public view returns (uint256) {
    return accounts[_account].actualLockedTokenAmount;
  }

  /**
   * @dev Returns the increment of cumulated rewards during the “lastSyncTimestamp” and current block.timestamp.
   * @param _account address Address of the account whose rewards will be calculated.
   */
  function getCumulatedRewardsIncrement(address _account) public view returns (uint256) {
    return _getCumulatedRewardsIncrement(_account);
  }

  /**
   * @dev Calculates the increment of cumulated rewards during the “lastSyncTimestamp” and block.timestamp.
   * current block timestamp and lastSyncTimestamp are confined in [PROGRAM_START, PROGRAM_END] for basic and boosted lockup,
   * @param _account address Address of the account whose rewards will be calculated.
   */
  function _getCumulatedRewardsIncrement(address _account) internal view returns (uint256) {
    Account memory account = accounts[_account];
    if (block.timestamp <= PROGRAM_START || account.lastSyncTimestamp >= PROGRAM_END) {
      // skip calculation and return directly 0;
      return 0;
    }
    // Per second gain, for basic lock-up.
    uint256 gainPerSec = account.actualLockedTokenAmount * BASIC_FACTOR_NUMERATOR;

    // Per second gain, for additional boost, applicable to amount under BOOST_CAP
    for (uint256 index = 0; index < redeemedFactorIndex[_account]; index++) {
      uint256 tokenId = redeemedFactor[_account][index];
      (uint256 boost, ) = NFT_CONTRACT.boostOf(tokenId);
      gainPerSec += (account.actualLockedTokenAmount.min(BOOST_CAP)) * boost;
    }

    return
      (gainPerSec *
        (block.timestamp.max(PROGRAM_START).min(PROGRAM_END) -
          account.lastSyncTimestamp.max(PROGRAM_START).min(PROGRAM_END))) / FACTOR_DENOMINATOR;
  }

  /**
   * @dev if the given `tokenURI` end with `/substring`
   * @param tokenURI string URI of the HoprBoost NFT. E.g. "https://stake.hoprnet.org/PuzzleHunt_v2/Bronze - Week 5"
   * @param substring string of the `boostRank` or `boostType/boostRank`. E.g. "Bronze - Week 5", "PuzzleHunt_v2/Bronze - Week 5"
   */
  function _hasSubstring(string memory tokenURI, string memory substring) internal pure returns (bool) {
    // convert string to bytes
    bytes memory tokenURIInBytes = bytes(tokenURI);
    bytes memory substringInBytes = bytes(substring);

    // lenghth of tokenURI is the sum of substringLen and restLen, where
    // - `substringLen` is the length of the part that is extracted and compared with the provided substring
    // - `restLen` is the length of the baseURI and boostType, which will be offset
    uint256 substringLen = substringInBytes.length;
    uint256 restLen = tokenURIInBytes.length - substringLen;
    // one byte before the supposed substring, to see if it's the start of `substring`
    bytes1 slashPositionContent = tokenURIInBytes[restLen - 1];

    if (slashPositionContent != 0x2f) {
      // if this position is not a `/`, substring in the tokenURI is for sure neither `boostRank` nor `boostType/boostRank`
      return false;
    }

    // offset so that value from the next calldata (`substring`) is removed, so bitwise it needs to shift
    // log2(16) * (32 - substringLen) * 2
    uint256 offset = (32 - substringLen) * 8;

    bytes32 trimed; // left-padded extracted `boostRank` from the `tokenURI`
    bytes32 substringInBytes32 = bytes32(substringInBytes); // convert substring in to bytes32
    bytes32 shifted; // shift the substringInBytes32 from right-padded to left-padded

    bool result;
    assembly {
      // assuming `boostRank` or `boostType/boostRank` will never exceed 32 bytes
      // left-pad the `boostRank` extracted from the `tokenURI`, so that possible
      // extra pieces of `substring` is not included
      // 32 jumps the storage of bytes length and restLen offsets the `baseURI`
      trimed := shr(offset, mload(add(add(tokenURIInBytes, 32), restLen)))
      // tokenURIInBytes32 := mload(add(add(tokenURIInBytes, 32), restLen))
      // left-pad `substring`
      shifted := shr(offset, substringInBytes32)
      // compare results
      result := eq(trimed, shifted)
    }
    return result;
  }

  /**
   * @dev Update “lastSyncTimestamp” with the current block timestamp and update “cumulatedRewards” with _getCumulatedRewardsIncrement(account)
   * @param _account address Address of the account whose rewards will be calculated.
   */
  function _sync(address _account) internal {
    uint256 increment = _getCumulatedRewardsIncrement(_account);
    accounts[_account].cumulatedRewards += increment;
    accounts[_account].lastSyncTimestamp = block.timestamp;
    emit Sync(_account, increment);
  }

  /**
   * @dev Claim rewards for staking.
   * @param _account address Address of the staking account.
   */
  function _claim(address _account) internal {
    Account memory account = accounts[_account];
    // update states
    uint256 amount = account.cumulatedRewards - account.claimedRewards;
    if (amount > 0) {
      accounts[_account].claimedRewards = accounts[_account].cumulatedRewards;
      require(availableReward >= amount, 'HoprStake: Insufficient reward pool.');
      availableReward -= amount;
      // send rewards to the account.
      IERC20(REWARD_TOKEN).safeTransfer(_account, amount);
      emit Claimed(_account, amount);
    }
  }

  /**
   * @dev Unlock staking for a given account
   * @param _account address Account that staked tokens.
   */
  function _unlockFor(address _account) internal {
    require(block.timestamp > PROGRAM_END, 'HoprStake: Program is ongoing, cannot unlock stake.');
    uint256 actualStake = accounts[_account].actualLockedTokenAmount;
    _sync(_account);
    accounts[_account].actualLockedTokenAmount = 0;
    totalLocked -= actualStake;
    _claim(_account);
    // unlock actual staked tokens
    IERC20(LOCK_TOKEN).safeTransfer(_account, actualStake);
    // unlock redeemed NFTs
    for (uint256 index = 0; index < redeemedNftIndex[_account]; index++) {
      NFT_CONTRACT.transferFrom(address(this), _account, redeemedNft[_account][index]);
    }
    emit Released(_account, actualStake);
  }

  /**
   * @dev Internal function to block an NFT
   * @param typeIndex integer Type index to be blocked
   */
  function _ownerBlockNftType(uint256 typeIndex) internal {
    isBlockedNft[typeIndex] = true;
    emit NftBlocked(typeIndex);
  }
}
