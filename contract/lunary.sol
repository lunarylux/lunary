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
        address token; // address(0) = POL, address(this) = LUX, lain = ERC-20
        uint256 amount;
        uint256 executeAfter;
        bool executed;
    }
    mapping(bytes32 => Rescue) public rescues;
    bytes32[] public rescueIds;

    // ============ EVENT ============
    event MiningStarted(address indexed user, uint256 startTime, bytes32 challenge);
    event MiningClaimed(address indexed user, uint256 reward, uint256 epoch);
    event MiningCancelled(address indexed user);
    event RescueCreated(bytes32 indexed id, address token, uint256 amount, uint256 executeAfter);
    event RescueExecuted(bytes32 indexed id, address token, uint256 amount);
    event RescueCancelled(bytes32 indexed id);

    // ============ CONSTRUCTOR ============
    constructor() ERC20("Lunary", "LUX") Ownable(msg.sender) {}

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

    // ============ MINING ============
    function startMining(bytes32 clientSeed) external nonReentrant whenNotPaused {
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

        // Verifikasi PoW
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

    // ============ TERIMA POL / ERC-20 ============
    receive() external payable {}

    // ============ RESCUE ============
    /**
     * @notice Buat rescue untuk token yang salah kirim
     * @param token address(0) = POL, address(this) = LUX, lain = ERC-20
     * @param amount Jumlah yang di-rescue
     * @dev Rescue LUX TIDAK mengubah totalMined / totalClaims / epoch
     */
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

    /**
     * @notice Execute rescue setelah 1 hari
     * @dev SELALU ke owner. Rescue LUX = transfer biasa.
     */
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
