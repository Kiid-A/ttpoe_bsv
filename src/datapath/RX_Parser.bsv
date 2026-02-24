package RX_Parser;

import FIFOF::*;
import GetPut::*;
import TTPoE_Types::*;
import TTPoE_Headers::*;


// =========================================================================
// 1. 硬件接口定义
// =========================================================================
interface RX_Parser_Ifc;
    // --- 消费者接口：接收来自底层物理网卡 (MAC) 的以太网帧 ---
    interface Put#(Raw_MAC_Frame) mac_rx_in;
    
    // --- 生产者接口：慢车道 (将解析出的事件发给 Arbiter 的 RXQ) ---
    interface Get#(EventReq) rx_event_out;
    
    // --- 生产者接口：快车道 (将合法的 Payload 数据直接推给主机 NOC) ---
    interface Get#(Raw_MAC_Frame) noc_payload_out;
endinterface

// =========================================================================
// 2. 模块实现 (注意：这里将 TMU 的接口作为模块参数传入，实现跨模块校验)
// =========================================================================
import TMU::*;

// (* synthesize *)
module mkRX_Parser#(TMU_Ifc tmu)(RX_Parser_Ifc);

    // 内部缓冲 FIFO
    FIFOF#(Raw_MAC_Frame) mac_in_q     <- mkFIFOF;
    FIFOF#(EventReq)      rx_event_q   <- mkFIFOF;
    FIFOF#(Raw_MAC_Frame) noc_out_q    <- mkFIFOF;

    // =====================================================================
    // 辅助函数：将报文中的 MAC 和 VC 拼装成 64-bit 主键 KID
    // =====================================================================
    function Bit#(64) generate_kid(MAC_Addr mac, Bit#(2) vc);
        TTP_KID kid_struct = TTP_KID {
            mac_lsb: truncate(mac), // 取 MAC 低 24 位
            vci: vc,
            is_gw: False,
            is_ipv4: False,
            reserved: 0
        };
        return pack(kid_struct); // pack 函数将结构体打平成 64 根电线
    endfunction

    // =====================================================================
    // 辅助函数：将报文中的 6-bit Opcode 翻译为 FSM 认识的 5-bit 事件
    // (参考 TTPoE 规范文档中的 Opcode 定义)
    // =====================================================================
    function TTPoE_Event map_opcode_to_event(Bit#(6) opcode);
        case (opcode)
            6'h00: return EV_RXQ_TTP_OPEN;
            6'h01: return EV_RXQ_TTP_OPEN_ACK;
            6'h03: return EV_RXQ_TTP_CLOSE;
            6'h04: return EV_RXQ_TTP_CLOSE_ACK;
            6'h06: return EV_RXQ_TTP_PAYLOAD;
            6'h07: return EV_RXQ_TTP_ACK;
            // ... 其他 opcode 映射略 ...
            default: return EV_NULL;
        endcase
    endfunction

    // =====================================================================
    // 核心流水线规则：流式解析与动静分离 (Bypass Logic)
    // =====================================================================
    rule rl_parse_packet (mac_in_q.notEmpty());
        let frame = mac_in_q.first();
        mac_in_q.deq();

        // 1. 提取 KID 和 事件类型 (纯组合逻辑，瞬间完成)
        Bit#(64)    kid = generate_kid(frame.eth.src_mac, frame.ttp.vci);
        TTPoE_Event evt = map_opcode_to_event(frame.ttp.opcode);

        // 2. 动静分离逻辑判定
        if (evt == EV_RXQ_TTP_PAYLOAD) begin
            // -------------------------------------------------------------
            // 【快车道 - Fast Path】: 这是数据流！
            // -------------------------------------------------------------
            // 步骤 A: 直接调用 TMU 的接口，进行极其严格的序列号 In-order 检查
            Bool is_valid_seq = tmu.check_rx_seq(kid, frame.ttp.tx_seq);

            if (is_valid_seq) begin
                // 完美！包合法。直接扔给 DMA/NOC，完全不打扰 FSM
                noc_out_q.enq(frame);
                
                // 叫 TMU 把 rx_seq_id + 1
                tmu.update_rx_seq(kid);
                
                // 依然需要生成一个事件告诉 FSM：“我收到了合法数据，请安排发 ACK”
                rx_event_q.enq(EventReq { kid: kid, event_type: EV_RXQ_TTP_PAYLOAD });
            end
            else begin
                // 序列号不对 (可能是乱序或重传旧包)
                // 生成 NACK 事件交给 FSM 去走慢车道报错流程
                rx_event_q.enq(EventReq { kid: kid, event_type: EV_RXQ_TTP_NACK });
            end
        end
        else begin
            // -------------------------------------------------------------
            // 【慢车道 - Slow Path】: 握手、断链等控制包
            // -------------------------------------------------------------
            // 控制流不需要快车道，直接打包成事件，丢给 Arbiter
            rx_event_q.enq(EventReq { kid: kid, event_type: evt });
        end
    endrule

    // =====================================================================
    // 接口连线
    // =====================================================================
    interface mac_rx_in       = toPut(mac_in_q);
    interface rx_event_out    = toGet(rx_event_q);
    interface noc_payload_out = toGet(noc_out_q);

endmodule

endpackage: RX_Parser