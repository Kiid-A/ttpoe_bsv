// =========================================================================
// File: src/datapath/TX_Builder.bsv
// Description: TTPoE 发送组包器 (TX Builder)
//              执行 FSM 下达的 Response 指令，抓取数据与序号，组装以太网帧
// =========================================================================

package TX_Builder;

import FIFOF::*;
import GetPut::*;
import TTPoE_Types::*;
import TTPoE_Headers::*;

// 引入 TMU 接口，因为发包需要查最新的序列号
import TMU::*;

// =========================================================================
// 1. 硬件接口定义
// =========================================================================
interface TX_Builder_Ifc;
    // --- 消费者接口：接收来自主机的原始数据载荷 (Payload) ---
    interface Put#(Raw_MAC_Frame) noc_tx_in;
    
    // --- 消费者接口：接收 FSM 的控制动作指令 ---
    // (FSM 决策出 Response 后，调用此接口命令 TX_Builder 发包)
    method Action generate_ctrl_pkt(Bit#(64) kid, TTPoE_Response rs);
    
    // --- 生产者接口：将组装好的以太网帧喷射给物理 MAC ---
    interface Get#(Raw_MAC_Frame) mac_tx_out;
endinterface

// FSM 指令的内部缓冲结构体
typedef struct {
    Bit#(64)       kid;
    TTPoE_Response rs;
} CmdReq deriving (Bits, Eq);

// =========================================================================
// 2. 模块实现
// =========================================================================
// (* synthesize *)
module mkTX_Builder#(TMU_Ifc tmu)(TX_Builder_Ifc);

    // 内部缓冲 FIFO
    FIFOF#(Raw_MAC_Frame) noc_in_q  <- mkFIFOF; // 主机推过来的数据
    FIFOF#(CmdReq)        cmd_q     <- mkFIFOF; // FSM 下达的命令
    FIFOF#(Raw_MAC_Frame) mac_out_q <- mkFIFOF; // 组装完毕准备发送的包

    // =====================================================================
    // 核心流水线规则：根据 FSM 的命令组装报文
    // =====================================================================
    rule rl_build_packet (cmd_q.notEmpty());
        let cmd = cmd_q.first();
        cmd_q.deq();

        // 1. 无动作直接丢弃
        if (cmd.rs == RS_NONE || cmd.rs == RS_STALL || cmd.rs == RS_DROP) begin
            // 硬件什么都不发
        end
        else begin
            // 2. 向 TMU 索要当前的序列号上下文 (用于捎带 ACK)
            // read_context 是纯组合逻辑方法，瞬间返回
            TagContext ctx = tmu.read_context(cmd.kid);

            // 准备组装报文
            Raw_MAC_Frame pkt;
            pkt.has_payload = False;
            
            // 填充以太网头部 (还原 MAC 地址)
            pkt.eth.dst_mac  = {24'h000000, truncate(cmd.kid)}; // 演示简化版MAC还原
            pkt.eth.src_mac  = 48'hAA_BB_CC_DD_EE_FF;           // 本机 MAC 地址
            pkt.eth.eth_type = c_TTP_ETHER_TYPE;

            // 填充基础 TTP 头部
            pkt.ttp.vci         = truncate(cmd.kid >> 24); // 从 KID 中还原 VC
            pkt.ttp.flags       = 8'h00;
            pkt.ttp.rx_seq      = ctx.rx_seq_id; // 所有发出的包都会捎带最新的确认号
            pkt.ttp.reserved    = 0;

            // 3. 根据具体的 Response 动作进行差异化组包
            if (cmd.rs == RS_PAYLOAD) begin
                // 发送数据载荷：必须从主机 NOC 队列中拿数据
                let host_data = noc_in_q.first();
                noc_in_q.deq();

                // 获取并自增发送序号 (ActionValue 产生硬件副作用)
                Bit#(32) tx_seq <- tmu.get_and_inc_tx_seq(cmd.kid);

                pkt.has_payload     = True;
                pkt.ttp.opcode      = 6'h06; // TTP_PAYLOAD
                pkt.ttp.payload_len = host_data.ttp.payload_len;
                pkt.ttp.tx_seq      = tx_seq;
                
                // 真实硬件中这里会将 host_data 的真实载荷总线连过来
            end
            else if (cmd.rs == RS_OPEN) begin
                // 发送建链请求 (控制包)
                pkt.ttp.opcode      = 6'h00; // TTP_OPEN
                pkt.ttp.payload_len = 0;
                pkt.ttp.tx_seq      = ctx.tx_seq_id; // OPEN 不自增序号
            end
            else if (cmd.rs == RS_ACK) begin
                // 发送纯确认包
                pkt.ttp.opcode      = 6'h07; // TTP_ACK
                pkt.ttp.payload_len = 0;
                pkt.ttp.tx_seq      = ctx.tx_seq_id; 
            end
            else if (cmd.rs == RS_CLOSE) begin
                // 发送断链请求
                pkt.ttp.opcode      = 6'h03; // TTP_CLOSE
                pkt.ttp.payload_len = 0;
                pkt.ttp.tx_seq      = ctx.tx_seq_id;
            end
            // ... (此处省略 RS_NACK, RS_OPEN_ACK 等其余分支的组包) ...
            
            // 4. 将组装好的完美以太网帧打入物理网卡发送 FIFO
            mac_out_q.enq(pkt);
        end
    endrule

    // =====================================================================
    // 接口连线
    // =====================================================================
    interface noc_tx_in  = toPut(noc_in_q);
    interface mac_tx_out = toGet(mac_out_q);

    method Action generate_ctrl_pkt(Bit#(64) kid, TTPoE_Response rs);
        cmd_q.enq(CmdReq { kid: kid, rs: rs });
    endmethod

endmodule

endpackage: TX_Builder