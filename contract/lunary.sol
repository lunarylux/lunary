// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/utils/Pausable.sol";
import "@openzeppelin/contracts/access/Ownable.sol";

/**
 * @title Lunary (LUX)
 * @notice Fair launch PoW mining token with 4x halving.
 *         Decimals 8, max supply 112,333.
 */
contract Lunary is ERC20, Pausable, ReentrancyGuard, Ownable {
    using SafeERC20 for IERC20;

    // ============ TOKEN CONSTANTS ============
    uint8 private constant _DECIMALS = 8;
    uint256 public constant MAX_SUPPLY = 112_333 * 10**_DECIMALS;

    // ============ MINING CONSTANTS ============
    uint256 public constant MINING_DURATION = 4 hours;
    uint256 public constant TOKENS_PER_CLAIM = 1 * 10**_DECIMALS;
    uint256 public constant CLAIMS_PER_EPOCH = 59_911;
    uint256 public constant MAX_HALVINGS = 4;

    // ============ SECURITY CONSTANTS ============
    uint256 public constant DIFFICULTY = 100_000;
    uint256 public constant RESCUE_DELAY = 1 days;

    // ============ FEE DEFAULT ============
    uint256 public constant DEFAULT_MINER_FEE = 1 ether;

    // ============ MIN CLAIM TO WALLET ============
    uint256 public constant BASE_MIN_CLAIM = 20 * 10**_DECIMALS;

    // ============ STATE ============
    uint256 public totalClaims;
    uint256 public totalMined;

    struct Session {
        uint256 startTime;
        bytes32 challenge;
        bool active;
        bool claimed;
    }
    mapping(address => Session) public sessions;

    struct Rescue {
        address token;
        uint256 amount;
        uint256 executeAfter;
        bool executed;
    }
    mapping(bytes32 => Rescue) public rescues;
    bytes32[] public rescueIds;

    // ============ MINER FEE STATE ============
    bool public minerFeeEnabled;
    uint256 public minerFee;
    address public feeRecipient;
    uint256 public accumulatedFees;
    mapping(address => bool) public authorizedMiners;
    uint256 public totalAuthorizedMiners;

    // ============ PENDING CLAIM STATE ============
    mapping(address => uint256) public minedBalance;
    uint256 public totalPendingClaims;

    // ============ EVENTS ============
    event MiningStarted(address indexed user, uint256 startTime, bytes32 challenge);
    event MiningClaimed(address indexed user, uint256 reward, uint256 epoch);
    event MiningCancelled(address indexed user);
    event RescueCreated(bytes32 indexed id, address token, uint256 amount, uint256 executeAfter);
    event RescueExecuted(bytes32 indexed id, address token, uint256 amount);
    event RescueCancelled(bytes32 indexed id);
    event MinerFeeUpdated(uint256 oldFee, uint256 newFee);
    event MinerFeeEnabledUpdated(bool enabled);
    event FeeRecipientUpdated(address oldRecipient, address newRecipient);
    event MinerAdded(address indexed miner, uint256 feePaid, address indexed payer);
    event MinerRemoved(address indexed miner);
    event FeesWithdrawn(address indexed to, uint256 amount);
    event MinedAccumulated(address indexed user, uint256 amount, uint256 newBalance);
    event WithdrawnToWallet(address indexed user, uint256 amount);

    // ============ CONSTRUCTOR ============
    constructor() ERC20("Lunary", "LUX") Ownable(msg.sender) {
        minerFeeEnabled = true;
        minerFee = DEFAULT_MINER_FEE;
        feeRecipient = msg.sender;
    }

    // ============ DECIMALS ============
    function decimals() public pure override returns (uint8) {
        return _DECIMALS;
    }

    // ============ VIEWS ============
    function currentEpoch() public view returns (uint256) {
        return totalClaims / CLAIMS_PER_EPOCH;
    }

    function currentReward() public view returns (uint256) {
        uint256 halvings = currentEpoch();
        if (halvings >= MAX_HALVINGS) return 0;
        return TOKENS_PER_CLAIM >> halvings;
    }

    function minClaimAmount() public view returns (uint256) {
        uint256 halvings = currentEpoch();
        if (halvings >= MAX_HALVINGS) {
            return BASE_MIN_CLAIM >> MAX_HALVINGS;
        }
        return BASE_MIN_CLAIM >> halvings;
    }

    function canClaim(address user) public view returns (bool) {
        Session memory s = sessions[user];
        if (!s.active || s.claimed) return false;
        return block.timestamp >= s.startTime + MINING_DURATION;
    }

    function timeRemaining(address user) public view returns (uint256) {
        Session memory s = sessions[user];
        if (!s.active || s.claimed) return 0;
        uint256 endTime = s.startTime + MINING_DURATION;
        if (block.timestamp >= endTime) return 0;
        return endTime - block.timestamp;
    }

    function maxSupply() external pure returns (uint256) {
        return MAX_SUPPLY;
    }

    function circulatingSupply() external view returns (uint256) {
        return totalSupply();
    }

    function remainingMineable() external view returns (uint256) {
        return MAX_SUPPLY - totalMined;
    }

    function currentDifficulty() external pure returns (uint256) {
        return DIFFICULTY;
    }

    function isMinerAllowed(address user) public view returns (bool) {
        if (!minerFeeEnabled) return true;
        return authorizedMiners[user];
    }

    function canWithdraw(address user) public view returns (bool) {
        return minedBalance[user] >= minClaimAmount();
    }

    function getMinedBalance(address user) external view returns (uint256) {
        return minedBalance[user];
    }

    function amountNeededToWithdraw(address user) external view returns (uint256) {
        uint256 bal = minedBalance[user];
        uint256 minRequired = minClaimAmount();
        if (bal >= minRequired) return 0;
        return minRequired - bal;
    }

    // ============ INTERNAL: SAFE LUX RESERVE ============
    /// @dev Mengembalikan saldo LUX kontrak yang TIDAK termasuk pending claims.
    ///      Aman terhadap underflow.
    function _availableLUX() internal view returns (uint256) {
        uint256 bal = balanceOf(address(this));
        uint256 pending = totalPendingClaims;
        if (bal <= pending) return 0;
        return bal - pending;
    }

    // ============ MINING ============
    function startMining(bytes32 clientSeed) external nonReentrant whenNotPaused {
        if (minerFeeEnabled) {
            require(authorizedMiners[msg.sender], "Miner not registered, pay fee first");
        }

        require(!sessions[msg.sender].active, "Already mining");
        require(currentReward() > 0, "Mining finished");
        require(totalMined < MAX_SUPPLY, "Max supply reached");

        bytes32 prevHash = block.number > 0 ? blockhash(block.number - 1) : bytes32(0);

        bytes32 challenge = keccak256(
            abi.encodePacked(prevHash, msg.sender, clientSeed, block.timestamp)
        );

        sessions[msg.sender] = Session({
            startTime: block.timestamp,
            challenge: challenge,
            active: true,
            claimed: false
        });

        emit MiningStarted(msg.sender, block.timestamp, challenge);
    }

    function claim(uint256 nonce) external nonReentrant whenNotPaused {
        Session storage s = sessions[msg.sender];
        require(s.active, "Mining not started");
        require(!s.claimed, "Already claimed");
        require(block.timestamp >= s.startTime + MINING_DURATION, "4 hours not passed");

        bytes32 hash = keccak256(abi.encodePacked(s.challenge, msg.sender, nonce));
        uint256 target = type(uint256).max / DIFFICULTY;
        require(uint256(hash) < target, "Invalid PoW");

        uint256 reward = currentReward();
        require(reward > 0, "Mining finished");
        require(totalMined + reward <= MAX_SUPPLY, "Max supply reached");

        s.claimed = true;
        s.active = false;
        totalMined += reward;
        totalClaims++;

        _mint(address(this), reward);
        minedBalance[msg.sender] += reward;
        totalPendingClaims += reward;

        emit MiningClaimed(msg.sender, reward, currentEpoch());
        emit MinedAccumulated(msg.sender, reward, minedBalance[msg.sender]);
    }

    function claimToWallet() external nonReentrant whenNotPaused {
        uint256 balance = minedBalance[msg.sender];
        uint256 minRequired = minClaimAmount();
        require(balance >= minRequired, "Below minimum claim");

        minedBalance[msg.sender] = 0;
        totalPendingClaims -= balance;

        _transfer(address(this), msg.sender, balance);

        emit WithdrawnToWallet(msg.sender, balance);
    }

    function cancelMining() external nonReentrant {
        Session storage s = sessions[msg.sender];
        require(s.active, "No active session");
        require(!s.claimed, "Already claimed");
        require(block.timestamp < s.startTime + MINING_DURATION, "4 hours passed");

        s.active = false;
        emit MiningCancelled(msg.sender);
    }

    // ============ MINER FEE MANAGEMENT ============
    function setMinerFee(uint256 newFee) external onlyOwner {
        uint256 oldFee = minerFee;
        minerFee = newFee;
        emit MinerFeeUpdated(oldFee, newFee);
    }

    function setMinerFeeEnabled(bool enabled) external onlyOwner {
        minerFeeEnabled = enabled;
        emit MinerFeeEnabledUpdated(enabled);
    }

    function setFeeRecipient(address newRecipient) external onlyOwner {
        require(newRecipient != address(0), "Recipient is zero");
        address oldRecipient = feeRecipient;
        feeRecipient = newRecipient;
        emit FeeRecipientUpdated(oldRecipient, newRecipient);
    }

    function addMiner(address miner) external payable nonReentrant whenNotPaused {
        require(miner != address(0), "Miner address is zero");
        require(!authorizedMiners[miner], "Miner already registered");

        uint256 requiredFee = minerFeeEnabled ? minerFee : 0;
        require(msg.value >= requiredFee, "Insufficient fee");

        authorizedMiners[miner] = true;
        totalAuthorizedMiners++;

        // Catat HANYA fee yang benar-benar dipakai (bukan seluruh msg.value)
        if (requiredFee > 0) {
            accumulatedFees += requiredFee;
        }

        // Refund kelebihan
        if (msg.value > requiredFee) {
            uint256 refund = msg.value - requiredFee;
            (bool ok, ) = msg.sender.call{value: refund}("");
            require(ok, "Refund failed");
        }

        emit MinerAdded(miner, requiredFee, msg.sender);
    }

    function addMinerBatch(address[] calldata miners) external payable nonReentrant whenNotPaused {
        uint256 len = miners.length;
        require(len > 0, "Empty array");

        uint256 requiredFee = minerFeeEnabled ? minerFee : 0;
        uint256 totalRequired = requiredFee * len;
        require(msg.value >= totalRequired, "Insufficient fee");

        uint256 added;
        for (uint256 i = 0; i < len; i++) {
            address m = miners[i];
            if (m == address(0) || authorizedMiners[m]) continue;
            authorizedMiners[m] = true;
            totalAuthorizedMiners++;
            added++;
            emit MinerAdded(m, requiredFee, msg.sender);
        }

        require(added > 0, "No new miners");

        uint256 used = requiredFee * added;
        if (used > 0) {
            accumulatedFees += used;
        }

        if (msg.value > used) {
            uint256 refund = msg.value - used;
            (bool ok, ) = msg.sender.call{value: refund}("");
            require(ok, "Refund failed");
        }
    }

    function removeMiner(address miner) external onlyOwner {
        require(authorizedMiners[miner], "Miner not registered");
        authorizedMiners[miner] = false;
        if (totalAuthorizedMiners > 0) {
            totalAuthorizedMiners--;
        }
        emit MinerRemoved(miner);
    }

    function withdrawFees() external nonReentrant {
        uint256 amount = accumulatedFees;
        require(amount > 0, "No fees");
        accumulatedFees = 0;

        address to = feeRecipient;
        require(to != address(0), "Fee recipient not set");

        (bool ok, ) = to.call{value: amount}("");
        require(ok, "Withdraw failed");

        emit FeesWithdrawn(to, amount);
    }

    function withdrawFeesTo(address to) external onlyOwner nonReentrant {
        require(to != address(0), "To address is zero");
        uint256 amount = accumulatedFees;
        require(amount > 0, "No fees");
        accumulatedFees = 0;

        (bool ok, ) = to.call{value: amount}("");
        require(ok, "Withdraw failed");

        emit FeesWithdrawn(to, amount);
    }

    // ============ RECEIVE ============
    receive() external payable {}

    // ============ RESCUE ============
    function createRescue(address token, uint256 amount) external onlyOwner returns (bytes32) {
        require(amount > 0, "Amount is zero");

        if (token == address(0)) {
            require(amount <= address(this).balance, "Insufficient POL balance");
        } else if (token == address(this)) {
            require(amount <= _availableLUX(), "Insufficient LUX (pending claims)");
        } else {
            require(IERC20(token).balanceOf(address(this)) >= amount, "Insufficient ERC20 balance");
        }

        bytes32 id = keccak256(abi.encodePacked(token, amount, block.timestamp, block.number));
        require(rescues[id].executeAfter == 0, "ID exists");

        rescues[id] = Rescue({
            token: token,
            amount: amount,
            executeAfter: block.timestamp + RESCUE_DELAY,
            executed: false
        });
        rescueIds.push(id);

        emit RescueCreated(id, token, amount, block.timestamp + RESCUE_DELAY);
        return id;
    }

    function executeRescue(bytes32 id) external onlyOwner nonReentrant {
        Rescue storage r = rescues[id];
        require(r.executeAfter > 0, "ID not found");
        require(!r.executed, "Already executed");
        require(block.timestamp >= r.executeAfter, "Not yet available");

        r.executed = true;
        address ownerAddr = owner();

        if (r.token == address(0)) {
            (bool ok, ) = ownerAddr.call{value: r.amount}("");
            require(ok, "POL transfer failed");
        } else if (r.token == address(this)) {
            require(r.amount <= _availableLUX(), "Insufficient LUX (pending claims)");
            _transfer(address(this), ownerAddr, r.amount);
        } else {
            IERC20(r.token).safeTransfer(ownerAddr, r.amount);
        }

        emit RescueExecuted(id, r.token, r.amount);
    }

    function cancelRescue(bytes32 id) external onlyOwner {
        Rescue storage r = rescues[id];
        require(r.executeAfter > 0, "ID not found");
        require(!r.executed, "Already executed");
        r.executed = true;
        emit RescueCancelled(id);
    }

    // ============ PAUSE ============
    function pause() external onlyOwner {
        _pause();
    }

    function unpause() external onlyOwner {
        _unpause();
    }

    // ============ GETTERS ============
    function getRescueIds() external view returns (bytes32[] memory) {
        return rescueIds;
    }

    function getRescueCount() external view returns (uint256) {
        return rescueIds.length;
    }

    function getTreasuryBalance() external view returns (uint256) {
        return address(this).balance;
    }

    function getERC20Balance(address token) external view returns (uint256) {
        return IERC20(token).balanceOf(address(this));
    }

    function getLUXBalance() external view returns (uint256) {
        return balanceOf(address(this));
    }

    function getAvailableLUXForRescue() external view returns (uint256) {
        return _availableLUX();
    }
}