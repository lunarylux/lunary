// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/utils/Pausable.sol";
import "@openzeppelin/contracts/access/Ownable.sol";

/**
 * @title Lunary (LUX)
 * @notice Fair launch token: PoW mining, 4x halving, tanpa tax
 * @dev Decimals 8, max supply 112.333, rescue LUX tidak ganggu mining
 * @dev + Fee untuk add miner baru (on/off, default 1 ETH)
 */
contract Lunary is ERC20, ReentrancyGuard, Pausable, Ownable {
    using SafeERC20 for IERC20;

    // ============ KONSTANTA TOKEN ============
    uint8 private constant _DECIMALS = 8;
    uint256 public constant MAX_SUPPLY = 112_333 * 10**_DECIMALS;

    // ============ KONSTANTA MINING ============
    uint256 public constant MINING_DURATION = 4 hours;
    uint256 public constant TOKENS_PER_CLAIM = 1 * 10**_DECIMALS;
    uint256 public constant CLAIMS_PER_EPOCH = 59_911;
    uint256 public constant MAX_HALVINGS = 4;

    // ============ KONSTANTA KEAMANAN ============
    uint256 public constant DIFFICULTY = 100_000;
    uint256 public constant RESCUE_DELAY = 1 days;

    // ============ DEFAULT FEE ============
    uint256 public constant DEFAULT_MINER_FEE = 1 ether; // 1 ETH (atau 1 native token)

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

    // ============ STATE FEE MINER ============
    /// @notice Status aktif/nonaktif fee untuk add miner baru
    bool public minerFeeEnabled;
    /// @notice Nominal fee untuk menambahkan miner baru (default 1 ETH)
    uint256 public minerFee;
    /// @notice Penerima fee (default owner)
    address public feeRecipient;
    /// @notice Total fee yang sudah terkumpul (belum di-withdraw)
    uint256 public accumulatedFees;
    /// @notice Daftar address miner yang sudah authorized (bayar fee)
    mapping(address => bool) public authorizedMiners;
    /// @notice Jumlah miner yang sudah authorized
    uint256 public totalAuthorizedMiners;

    // ============ EVENT ============
    event MiningStarted(address indexed user, uint256 startTime, bytes32 challenge);
    event MiningClaimed(address indexed user, uint256 reward, uint256 epoch);
    event MiningCancelled(address indexed user);
    event RescueCreated(bytes32 indexed id, address token, uint256 amount, uint256 executeAfter);
    event RescueExecuted(bytes32 indexed id, address token, uint256 amount);
    event RescueCancelled(bytes32 indexed id);

    // Event Fee
    event MinerFeeUpdated(uint256 oldFee, uint256 newFee);
    event MinerFeeEnabledUpdated(bool enabled);
    event FeeRecipientUpdated(address oldRecipient, address newRecipient);
    event MinerAdded(address indexed miner, uint256 feePaid, address indexed payer);
    event MinerRemoved(address indexed miner);
    event FeesWithdrawn(address indexed to, uint256 amount);

    // ============ CONSTRUCTOR ============
    constructor() ERC20("Lunary", "LUX") Ownable(msg.sender) {
        // Default: fee aktif dengan 1 ETH
        minerFeeEnabled = true;
        minerFee = DEFAULT_MINER_FEE;
        feeRecipient = msg.sender;
    }

    // ============ DECIMALS ============
    function decimals() public pure override returns (uint8) {
        return _DECIMALS;
    }

    // ============ VIEW ============
    function currentEpoch() public view returns (uint256) {
        return totalClaims / CLAIMS_PER_EPOCH;
    }

    function currentReward() public view returns (uint256) {
        uint256 halvings = currentEpoch();
        if (halvings >= MAX_HALVINGS) return 0;
        return TOKENS_PER_CLAIM >> halvings;
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

    /// @notice Cek apakah user boleh mining (berdasarkan status fee)
    function isMinerAllowed(address user) public view returns (bool) {
        if (!minerFeeEnabled) return true;
        return authorizedMiners[user];
    }

    // ============ MINING ============
    function startMining(bytes32 clientSeed) external nonReentrant whenNotPaused {
        // Jika fee aktif, user harus authorized
        if (minerFeeEnabled) {
            require(authorizedMiners[msg.sender], "Miner belum terdaftar, bayar fee dulu");
        }

        require(!sessions[msg.sender].active, "Sudah mining");
        require(currentReward() > 0, "Mining selesai");
        require(totalMined < MAX_SUPPLY, "Max supply tercapai");

        bytes32 challenge = keccak256(abi.encodePacked(
            blockhash(block.number - 1),
            msg.sender,
            clientSeed,
            block.timestamp
        ));

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
        require(s.active, "Belum mulai mining");
        require(!s.claimed, "Sudah claim");
        require(block.timestamp >= s.startTime + MINING_DURATION, "Belum 4 jam");

        bytes32 hash = keccak256(abi.encodePacked(s.challenge, msg.sender, nonce));
        uint256 target = type(uint256).max / DIFFICULTY;
        require(uint256(hash) < target, "PoW tidak valid");

        uint256 reward = currentReward();
        require(reward > 0, "Mining selesai");
        require(totalMined + reward <= MAX_SUPPLY, "Max supply tercapai");

        s.claimed = true;
        s.active = false;
        totalMined += reward;
        totalClaims++;

        _mint(msg.sender, reward);
        emit MiningClaimed(msg.sender, reward, currentEpoch());
    }

    function cancelMining() external nonReentrant {
        Session storage s = sessions[msg.sender];
        require(s.active, "Tidak ada session");
        require(!s.claimed, "Sudah claim");
        require(block.timestamp < s.startTime + MINING_DURATION, "Sudah 4 jam");

        s.active = false;
        emit MiningCancelled(msg.sender);
    }

    // ============ FEE MINER MANAGEMENT ============

    /**
     * @notice Set nominal fee untuk add miner baru
     * @param newFee Nominal fee dalam wei (native token)
     */
    function setMinerFee(uint256 newFee) external onlyOwner {
        uint256 oldFee = minerFee;
        minerFee = newFee;
        emit MinerFeeUpdated(oldFee, newFee);
    }

    /**
     * @notice Toggle on/off fee miner
     * @param enabled true = wajib bayar fee, false = bebas
     */
    function setMinerFeeEnabled(bool enabled) external onlyOwner {
        minerFeeEnabled = enabled;
        emit MinerFeeEnabledUpdated(enabled);
    }

    /**
     * @notice Set penerima fee
     * @param newRecipient Address penerima fee
     */
    function setFeeRecipient(address newRecipient) external onlyOwner {
        require(newRecipient != address(0), "Recipient 0");
        address oldRecipient = feeRecipient;
        feeRecipient = newRecipient;
        emit FeeRecipientUpdated(oldRecipient, newRecipient);
    }

    /**
     * @notice Tambah miner baru dengan bayar fee
     * @dev Jika minerFeeEnabled == false, fee = 0 (gratis)
     *      Jika minerFee == 0, juga gratis
     */
    function addMiner(address miner) external payable nonReentrant whenNotPaused {
        require(miner != address(0), "Miner address 0");
        require(!authorizedMiners[miner], "Miner sudah terdaftar");

        uint256 requiredFee = minerFeeEnabled ? minerFee : 0;
        require(msg.value >= requiredFee, "Fee kurang");

        authorizedMiners[miner] = true;
        totalAuthorizedMiners++;

        if (msg.value > 0) {
            accumulatedFees += msg.value;
        }

        // Refund kelebihan
        if (msg.value > requiredFee) {
            uint256 refund = msg.value - requiredFee;
            (bool ok, ) = msg.sender.call{value: refund}("");
            require(ok, "Refund gagal");
        }

        emit MinerAdded(miner, requiredFee, msg.sender);
    }

    /**
     * @notice Tambah banyak miner sekaligus
     * @dev Fee dihitung per miner
     */
    function addMinerBatch(address[] calldata miners) external payable nonReentrant whenNotPaused {
        uint256 len = miners.length;
        require(len > 0, "Array kosong");

        uint256 requiredFee = minerFeeEnabled ? minerFee : 0;
        uint256 totalRequired = requiredFee * len;
        require(msg.value >= totalRequired, "Fee kurang");

        uint256 added;
        for (uint256 i = 0; i < len; i++) {
            address m = miners[i];
            if (m == address(0) || authorizedMiners[m]) continue;
            authorizedMiners[m] = true;
            totalAuthorizedMiners++;
            added++;
            emit MinerAdded(m, requiredFee, msg.sender);
        }

        require(added > 0, "Tidak ada miner baru");

        uint256 used = requiredFee * added;
        if (used > 0) {
            accumulatedFees += used;
        }

        // Refund kelebihan
        if (msg.value > used) {
            uint256 refund = msg.value - used;
            (bool ok, ) = msg.sender.call{value: refund}("");
            require(ok, "Refund gagal");
        }
    }

    /**
     * @notice Hapus miner dari whitelist
     * @dev Tidak refund fee. Owner only.
     */
    function removeMiner(address miner) external onlyOwner {
        require(authorizedMiners[miner], "Miner tidak terdaftar");
        authorizedMiners[miner] = false;
        if (totalAuthorizedMiners > 0) {
            totalAuthorizedMiners--;
        }
        emit MinerRemoved(miner);
    }

    /**
     * @notice Withdraw fee yang terkumpul ke feeRecipient
     */
    function withdrawFees() external nonReentrant {
        uint256 amount = accumulatedFees;
        require(amount > 0, "Tidak ada fee");
        accumulatedFees = 0;

        address to = feeRecipient;
        (bool ok, ) = to.call{value: amount}("");
        require(ok, "Withdraw gagal");

        emit FeesWithdrawn(to, amount);
    }

    /**
     * @notice Withdraw fee ke address tertentu (owner only)
     */
    function withdrawFeesTo(address to) external onlyOwner nonReentrant {
        require(to != address(0), "To address 0");
        uint256 amount = accumulatedFees;
        require(amount > 0, "Tidak ada fee");
        accumulatedFees = 0;

        (bool ok, ) = to.call{value: amount}("");
        require(ok, "Withdraw gagal");

        emit FeesWithdrawn(to, amount);
    }

    // ============ TERIMA POL / ERC-20 ============
    receive() external payable {}

    // ============ RESCUE ============
    function createRescue(address token, uint256 amount) external onlyOwner returns (bytes32) {
        require(amount > 0, "Amount 0");

        if (token == address(0)) {
            require(amount <= address(this).balance, "Saldo POL kurang");
        } else if (token == address(this)) {
            require(amount <= balanceOf(address(this)), "Saldo LUX kurang");
        } else {
            require(IERC20(token).balanceOf(address(this)) >= amount, "Saldo ERC-20 kurang");
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
        require(r.executeAfter > 0, "ID tidak ada");
        require(!r.executed, "Sudah execute");
        require(block.timestamp >= r.executeAfter, "Belum waktunya");

        r.executed = true;
        address ownerAddr = owner();

        if (r.token == address(0)) {
            (bool ok, ) = ownerAddr.call{value: r.amount}("");
            require(ok, "Transfer POL gagal");
        } else if (r.token == address(this)) {
            _transfer(address(this), ownerAddr, r.amount);
        } else {
            IERC20(r.token).safeTransfer(ownerAddr, r.amount);
        }

        emit RescueExecuted(id, r.token, r.amount);
    }

    function cancelRescue(bytes32 id) external onlyOwner {
        Rescue storage r = rescues[id];
        require(r.executeAfter > 0, "ID tidak ada");
        require(!r.executed, "Sudah execute");
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

    // ============ GETTER ============
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
}