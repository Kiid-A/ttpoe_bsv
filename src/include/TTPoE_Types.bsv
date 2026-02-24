// define basic ttpoe types

package TTPoE_Types;

// 核心状态机
typedef enum {
    ST_STAY       = 3'd0,  // 特殊状态：保持当前状态不变
    ST_CLOSED     = 3'd1,  // 复位/初始状态
    ST_OPEN_SENT  = 3'd2,  // 主动建链中
    ST_OPEN_RECD  = 3'd3,  // 被动响应中 (等待分配Tag)
    ST_OPEN       = 3'd4,  // 数据面活跃稳态
    ST_CLOSE_SENT = 3'd5,  // 主动断链中
    ST_CLOSE_RECD = 3'd6,  // 被动断链中 (等待排空Quiesce)
    ST_INVALID    = 3'd7   // 非法状态掩码
} TTPoE_State deriving (Bits, Eq, FShow);

// 事件类型
typedef enum {
    EV_NULL                = 5'd0,
    
    // --- 主机端事件 (TXQ Events) ---
    EV_TXQ_TTP_OPEN        = 5'd1,
    EV_TXQ_TTP_CLOSE       = 5'd2,
    EV_TXQ_TTP_PAYLOAD     = 5'd3,
    EV_TXQ_REPLAY_DATA     = 5'd4,
    EV_TXQ_REPLAY_CLOSE    = 5'd5,
    
    // --- 网络端事件 (RXQ Events) ---
    EV_RXQ_TTP_OPEN        = 5'd6,
    EV_RXQ_TTP_OPEN_ACK    = 5'd7,
    EV_RXQ_TTP_OPEN_NACK   = 5'd8,
    EV_RXQ_TTP_CLOSE       = 5'd9,
    EV_RXQ_TTP_CLOSE_ACK   = 5'd10,
    EV_RXQ_TTP_CLOSE_NACK  = 5'd11,
    EV_RXQ_TTP_PAYLOAD     = 5'd12,
    EV_RXQ_TTP_ACK         = 5'd13,
    EV_RXQ_TTP_NACK        = 5'd14,
    EV_RXQ_TTP_NACK_FULL   = 5'd15,
    EV_RXQ_TTP_NACK_NOLINK = 5'd16,
    EV_RXQ_TTP_UNXP_PAYLD  = 5'd17,
    
    // --- 内部确认队列 (AKQ Events) ---
    EV_AKQ_OPEN_ACK        = 5'd18,
    EV_AKQ_OPEN_NACK       = 5'd19,
    EV_AKQ_CLOSE_ACK       = 5'd20,
    EV_AKQ_CLOSE_NACK      = 5'd21,
    EV_AKQ_ACK             = 5'd22,
    EV_AKQ_NACK            = 5'd23,
    
    // --- 内部管理事件 (INQ Events) ---
    EV_INQ_TIMEOUT         = 5'd24,  // 定时器超时重传
    EV_INQ_VICTIM          = 5'd25,  // 资源不足，被选为驱逐受害者
    EV_INQ_FOUND_WAY       = 5'd26,  
    EV_INQ_NO_WAY          = 5'd27,  
    EV_INQ_ALLOC_TAG       = 5'd28,  // Tag槽位分配成功
    EV_INQ_NO_TAG          = 5'd29,  // Tag槽位爆满分配失败
    EV_INQ_YES_QUIESCED    = 5'd30,  // NOC队列已排空
    EV_INQ_NOT_QUIESCED    = 5'd31   // NOC队列未排空
} TTPoE_Event deriving (Bits, Eq, FShow);

// 响应类型
typedef enum {
    RS_NONE        = 5'd0,   // 无响应 (静默处理)
    RS_OPEN        = 5'd1,   // 发送 TTP_OPEN
    RS_OPEN_ACK    = 5'd2,   // 发送 TTP_OPEN_ACK
    RS_OPEN_NACK   = 5'd3,   // 发送 TTP_OPEN_NACK
    RS_CLOSE       = 5'd4,   // 发送 TTP_CLOSE
    RS_CLOSE_ACK   = 5'd5,   // 发送 TTP_CLOSE_ACK
    RS_CLOSE_XACK  = 5'd6,   // 发送 TTP_CLOSE_XACK (携带预测序号的拒绝)
    RS_PAYLOAD     = 5'd7,   // 发送 常规数据载荷
    RS_PAYLOAD2    = 5'd8,   // 发送 挥手期残留数据载荷
    RS_ACK         = 5'd9,   // 发送 TTP_ACK
    RS_NACK        = 5'd10,  // 发送 TTP_NACK
    RS_NACK_NOLINK = 5'd11,  // 发送 TTP_NACK_NOLINK (警告无连接)
    RS_STALL       = 5'd12,  // 反压(挂起) 主机 NOC 总线
    RS_DROP        = 5'd13,  // 丢弃报文
    RS_REPLAY_DATA = 5'd14,  // 触发底层数据通路重传数据
    RS_NOC_FAIL    = 5'd15,  // 通知主机建链失败
    RS_NOC_END     = 5'd16,  // 通知主机连接已正常结束
    RS_ILLEGAL     = 5'd31   // 错误/非法动作抓取
} TTPoE_Response deriving (Bits, Eq, FShow);

// 事件结构体
typedef struct {
    Bit#(64)    kid;         // 连接主键 (MAC + VC 拼合)
    TTPoE_Event event_type;  // 触发的事件类型
    
    // Bit#(32)    pkt_tx_seq;  // 序号供比对
    // Bit#(32)    pkt_rx_seq;
} EventReq deriving (Bits, Eq, FShow);

endpackage: TTPoE_Types