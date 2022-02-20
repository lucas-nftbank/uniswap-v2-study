pragma solidity =0.5.16;

import './interfaces/IUniswapV2Factory.sol';
import './UniswapV2Pair.sol';

contract UniswapV2Factory is IUniswapV2Factory {
    address public feeTo;
    address public feeToSetter;

    mapping(address => mapping(address => address)) public getPair;
    address[] public allPairs;

    event PairCreated(address indexed token0, address indexed token1, address pair, uint);

    constructor(address _feeToSetter) public {
        feeToSetter = _feeToSetter;
    }

    function allPairsLength() external view returns (uint) {
        return allPairs.length;
    }

    function createPair(address tokenA, address tokenB) external returns (address pair) {
        require(tokenA != tokenB, 'UniswapV2: IDENTICAL_ADDRESSES');
        // 이렇게 sorting을 해줘야, 같은 두 토큰을 다루는 두 풀이 생기지 않는다. 풀은 뭉쳐 있어야지 슬리피지가 없어서 유리하다.
        (address token0, address token1) = tokenA < tokenB ? (tokenA, tokenB) : (tokenB, tokenA);
        require(token0 != address(0), 'UniswapV2: ZERO_ADDRESS');
        // 풀을 강제로 하나만 생기게 한다.
        require(getPair[token0][token1] == address(0), 'UniswapV2: PAIR_EXISTS'); // single check is sufficient
        bytes memory bytecode = type(UniswapV2Pair).creationCode;
        bytes32 salt = keccak256(abi.encodePacked(token0, token1));
        assembly {
            // 별도 정의 된 함수인데 풀 어드레스를 지정할 수 있다고 한다. 너무 테크니컬한 거라 넘어감.
            pair := create2(0, add(bytecode, 32), mload(bytecode), salt)
        }
        // 초기화함수를 이렇게 불러준다. 컨트랙트가 컨트랙트를 부를 때 이렇게 interface로 호출하기도 한다.
        IUniswapV2Pair(pair).initialize(token0, token1);
        getPair[token0][token1] = pair;
        // 사실 어차피 sorting하기 때문에 별 필요는 없지만 안전장치
        getPair[token1][token0] = pair; // populate mapping in the reverse direction
        allPairs.push(pair);
        emit PairCreated(token0, token1, pair, allPairs.length);
    }

    // 이 밑에 두 함수들은 swap fee의 일부를 프로토콜 전체(uniswap)으로 보낼 수 있게 만들어둔 것이다.
    function setFeeTo(address _feeTo) external {
        require(msg.sender == feeToSetter, 'UniswapV2: FORBIDDEN');
        feeTo = _feeTo;
    }

    function setFeeToSetter(address _feeToSetter) external {
        require(msg.sender == feeToSetter, 'UniswapV2: FORBIDDEN');
        feeToSetter = _feeToSetter;
    }
}
