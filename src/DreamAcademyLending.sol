// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "forge-std/Test.sol";
interface IPriceOracle {
    function getPrice(address token) external view returns (uint256);
    function setPrice(address token, uint256 price) external;
}

contract DreamAcademyLending {
    IPriceOracle public oracle;
    IERC20 public usdc;
    uint usdctotal;  // deposit 한 총량
    address[] users;
    struct Lending {
        uint amount;
        uint bnum;
    }
    mapping(address => uint) deptInterest;
    uint totaldept;
    mapping(address => uint)  depositUSDC;
    mapping(address => Lending)  LendingBalance;
    mapping(address => Lending)  depositETH; // 담보로 맡긴 Ether
    uint256 day_rate = 1001000000000000000 ;
    uint block_per_rate = 1000000139000000000 ;  // 하루 이자율이 0.1% 일때 한 블록당 이자율 0.000000139% 
                                    
    constructor(IPriceOracle target_oracle, address usdcAddress) {
        oracle = target_oracle;
        usdc = IERC20(usdcAddress);
    }
   function calc(uint principal, uint gap,uint rate) internal returns (uint result) { // 이자율 계산
        uint p = principal; 
        for (uint i = 0; i < gap; i++) {
            p = p * rate / 1 ether;
        }
        result = p - principal;
    }

    function interest(address user) internal {
        uint gap = (block.number - LendingBalance[user].bnum);  // 블록을 시간으로 초 단위로 변환
        uint day = gap / 7200;
        uint blocks = gap % 7200;
        console.log("gap",gap);
        if(gap>0){
            uint calcInterest = calc(totaldept, day, day_rate);
            LendingBalance[user].amount+=calcInterest;
            totaldept+=calcInterest;
            distributeInterest(calcInterest);
        
            uint calcInterest2 = calc(totaldept, blocks, block_per_rate);
            LendingBalance[user].amount+=calcInterest2;
            totaldept+=calcInterest2;
            distributeInterest(calcInterest2);
            LendingBalance[user].bnum= block.number;
        }
    }

    function getOracle() internal view returns (uint etherPrice, uint usdcPrice) {  
        etherPrice = oracle.getPrice(address(0x0));
        usdcPrice = oracle.getPrice(address(usdc));
    }

    function initializeLendingProtocol(address addr) external payable {
        usdc = IERC20(addr);
        usdc.transferFrom(msg.sender, address(this), msg.value);
    }

    function deposit(address token, uint256 amount) public payable {
        if (token == address(0x0)) { 
            require(msg.value == amount, "Invalid ETH amount");
            depositETH[msg.sender].amount += msg.value; // Ether를 담보로 예치
            depositETH[msg.sender].bnum = block.number; 
        } else {
            require(amount > 0, "Invalid usdc amount");
            if(depositUSDC[msg.sender]==0){ //새로운 유저의 deposit
                users.push(msg.sender);
            }
            depositUSDC[msg.sender] += amount;
            usdctotal += amount;
            console.log("total", usdctotal);
            IERC20(token).transferFrom(msg.sender, address(this), amount);
        }
    }

    function borrow(address token, uint amount) public {
        interest(msg.sender);
        (uint etherPrice, uint usdcPrice) = getOracle();

        uint collateralusdc = depositETH[msg.sender].amount * etherPrice / usdcPrice / 2 ;
        uint price = (LendingBalance[msg.sender].amount + amount) ;

        require(collateralusdc >= price, "Insufficient collateral");
        require(IERC20(token).balanceOf(address(this)) >= amount, "Insufficient amount");
        LendingBalance[msg.sender].bnum = block.number; 
        LendingBalance[msg.sender].amount += amount;
        totaldept+=amount;
        console.log("lending : ",LendingBalance[msg.sender].amount );
        IERC20(token).transfer(msg.sender, amount);
    }

    function repay(address token, uint amount) public {
        interest(msg.sender);
        require(LendingBalance[msg.sender].amount >= amount, "Insufficient supply");
        LendingBalance[msg.sender].amount -= amount;
        usdctotal-=amount;
        IERC20(token).transferFrom(msg.sender, address(this), amount);
    }

    function withdraw(address token, uint amount) public {
        interest(msg.sender);
        (uint etherPrice, uint usdcPrice) = getOracle();
        require(token == address(0x0) || token == address(usdc));
        if (token == address(0x0)) { 
            require(depositETH[msg.sender].amount >= amount, "Insufficient ETH");
            uint collateral = depositETH[msg.sender].amount - amount;
            uint value = LendingBalance[msg.sender].amount * usdcPrice / etherPrice;

            // LTV 75% 이하 유지
            require(value * 4 <= collateral * 3, "Insufficient collateral");
            depositETH[msg.sender].amount -= amount;
            msg.sender.call{value: amount}("");

        } 
        else {
            depositUSDC[msg.sender]+=deptInterest[msg.sender];
            deptInterest[msg.sender]=0;
            require(depositUSDC[msg.sender] >= amount, "Insufficient usdc");
            
            depositUSDC[msg.sender] -= amount;
            IERC20(token).transfer(msg.sender, amount);
        }
    }

    function liquidate(address borrower, address token, uint amount) public {
        interest(borrower);
        (uint etherPrice, uint usdcPrice) = getOracle();

        uint debt = LendingBalance[borrower].amount * usdcPrice / etherPrice;
        uint collateral = depositETH[borrower].amount;
        uint maxliquidate = LendingBalance[borrower].amount / 4;
        

        require(debt > collateral * 3 / 4); 
        require(amount <= maxliquidate); //청산은 25% 까지만 가능
        usdctotal-=amount;
        depositETH[borrower].amount -= amount * usdcPrice / etherPrice;
        LendingBalance[borrower].amount -= amount;
        IERC20(token).transfer(msg.sender, amount);
    }

    function getAccruedSupplyAmount(address token) public  returns (uint price) {
        interest(msg.sender);
        require(token == address(usdc));
        price = depositUSDC[msg.sender] + deptInterest[msg.sender];

    }

    receive() external payable {
    }

    function distributeInterest(uint totalInterest) internal {
    // 예치된 USDC에 대한 이자를 분배
    for (uint i=0; i<users.length; i++) {
        address user = users[i];                
        uint share = (depositUSDC[user] * totalInterest) / usdctotal;
        deptInterest[user] += share;
        }
    }
}
    

