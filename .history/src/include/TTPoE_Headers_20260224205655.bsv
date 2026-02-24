// 报文头部

package TTPoE_Headers;


// 基础网络类型
typedef Bit#(48) MAC_Addr;
typedef Bit#(32) IPv4_Addr;

Bit#(16) c_TTP_ETHER_TYPE = 16'h9AC6;

// 以太网头部
typedef struct {
    MAC_Addr dst_mac;
    MAC_Addr src_mac;
    Bit#(16) eth_type;
} Eth_Header deriving (Bits, Eq, FShow);

// TTPoE传输头部
typedef struct {
    Bit#(6)  opcode;      // 对应网络控制指令
    Bit#(2)  vci;         // 虚拟通道
    
    Bit#(8)  flags;       // 控制标志位
    Bit#(16) payload_len; // 载荷长度
    
    Bit#(32) tx_seq;      // 发送端当前的包序号
    Bit#(32) rx_seq;      // 发送端期望接收的下一个序号
    
    Bit#(32) reserved;    // 填充位，保证 128-bit 总线对齐
} TTP_Header deriving (Bits, Eq, FShow);

// 哈希表主键
typedef struct {
    Bit#(24) mac_lsb;     // 对端 MAC 地址的低 24 位
    Bit#(2)  vci;         // 虚拟通道
    
    // 拓扑标志位
    Bool     is_gw;
    Bool     is_ipv4;
    
    // padding
    Bit#(36) reserved;    
} TTP_KID deriving (Bits, Eq, FShow);

// 解析结果
typedef struct {
    TTP_KID  kid;         // 提取并拼装好的 64-bit 主键
    Bit#(6)  opcode;      // 原始网络操作码
    Bit#(32) tx_seq;      // 提取的对方发送序号
    Bit#(32) rx_seq;      // 提取的对方确认序号
    Bool     has_payload; // 是否携带需要 DMA 搬运的数据
} Parsed_Pkt_Info deriving (Bits, Eq, FShow);

// =========================================================================
// 6. 顶层网卡 MAC 数据流复合结构体 (新增)
// 用于 RX/TX Datapath 以及 Top 顶层流转的以太网帧模型
// =========================================================================
typedef struct {
    Eth_Header eth;
    TTP_Header ttp;
    Bool       has_payload;
    // 真实硬件中这里还会有一根宽总线 (如 Bit#(512)) 携带真实数据载荷
} Raw_MAC_Frame deriving (Bits, Eq, FShow);

endpackage: TTPoE_Headers