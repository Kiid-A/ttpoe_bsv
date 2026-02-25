package TX_Builder;

import FIFOF::*;
import GetPut::*;
import TTPoE_Types::*;
import TTPoE_Headers::*;
import TMU::*;

interface TX_Builder_Ifc;
    interface Put#(Raw_MAC_Frame) noc_tx_in;
    method Action generate_ctrl_pkt(Bit#(64) kid, TTPoE_Response rs);
    interface Get#(Raw_MAC_Frame) mac_tx_out;
endinterface

typedef struct {
    Bit#(64)       kid;
    TTPoE_Response rs;
} CmdReq deriving (Bits, Eq);

module mkTX_Builder#(TMU_Ifc tmu)(TX_Builder_Ifc);
    FIFOF#(Raw_MAC_Frame) noc_in_q  <- mkFIFOF;
    FIFOF#(CmdReq)        cmd_q     <- mkFIFOF;
    FIFOF#(Raw_MAC_Frame) mac_out_q <- mkFIFOF;

    Reg#(UInt#(16)) dbg_cycle <- mkReg(0);

    rule rl_dbg_queues;
        dbg_cycle <= dbg_cycle + 1;
        if ((dbg_cycle % 5) == 0) begin
            $display("[TX][DBG] cmd_q=%0d noc_in=%0d mac_out=%0d",
                     pack(cmd_q.notEmpty), pack(noc_in_q.notEmpty), pack(mac_out_q.notEmpty));
        end
    endrule

    // =====================================================================
    // Rule 1: 专职处理 控制报文 (无需读取 NOC 数据，彻底消除阻塞)
    // =====================================================================
    rule rl_build_ctrl_packet (cmd_q.notEmpty() && cmd_q.first().rs != RS_PAYLOAD && cmd_q.first().rs != RS_PAYLOAD2);
        let cmd = cmd_q.first();
        cmd_q.deq();

        if (cmd.rs == RS_NONE || cmd.rs == RS_STALL || cmd.rs == RS_DROP) begin
            // 硬件静默丢弃
        end
        else begin
            Raw_MAC_Frame pkt;
            pkt.has_payload = False;
            pkt.eth.dst_mac  = {24'h000000, truncate(cmd.kid)};
            pkt.eth.src_mac  = 48'hAA_BB_CC_DD_EE_FF;
            pkt.eth.eth_type = c_TTP_ETHER_TYPE;
            
            pkt.ttp.vci         = truncate(cmd.kid >> 24);
            pkt.ttp.flags       = 8'h00;
            pkt.ttp.rx_seq      = 0;
            pkt.ttp.reserved    = 0;
            pkt.ttp.payload_len = 0;
            pkt.ttp.tx_seq      = 0;
            pkt.ttp.opcode      = 6'h00; // default init
            
            Bool do_send = True;
            if      (cmd.rs == RS_OPEN)       pkt.ttp.opcode = 6'h00;
            else if (cmd.rs == RS_OPEN_ACK)   pkt.ttp.opcode = 6'h01;
            else if (cmd.rs == RS_OPEN_NACK)  pkt.ttp.opcode = 6'h02;
            else if (cmd.rs == RS_CLOSE)      pkt.ttp.opcode = 6'h03;
            else if (cmd.rs == RS_CLOSE_ACK)  pkt.ttp.opcode = 6'h04;
            else if (cmd.rs == RS_CLOSE_XACK) pkt.ttp.opcode = 6'h05;
            else if (cmd.rs == RS_ACK)        pkt.ttp.opcode = 6'h07;
            else if (cmd.rs == RS_NACK)       pkt.ttp.opcode = 6'h08;
            else if (cmd.rs == RS_NACK_NOLINK)pkt.ttp.opcode = 6'h09;
            else do_send = False;

            if (do_send) begin
                $display("[TX] send CTRL opcode=%0h tx_seq=%0d", pkt.ttp.opcode, pkt.ttp.tx_seq);
                mac_out_q.enq(pkt);
            end
        end
    endrule

    // =====================================================================
    // Rule 2: 专职处理 数据报文 (依赖 NOC 数据和 Cmd 协同就绪)
    // =====================================================================
    rule rl_build_data_packet (cmd_q.notEmpty() && (cmd_q.first().rs == RS_PAYLOAD || cmd_q.first().rs == RS_PAYLOAD2));
        let cmd = cmd_q.first();
        cmd_q.deq();
        
        // 走到这里时，BSV 会安全地将 noc_in_q.notEmpty 提升为条件
        let host_data = noc_in_q.first();
        noc_in_q.deq();

        Bit#(32) tx_seq <- tmu.get_and_inc_tx_seq(cmd.kid);

        Raw_MAC_Frame pkt;
        pkt.has_payload     = True;
        pkt.eth.dst_mac     = {24'h000000, truncate(cmd.kid)};
        pkt.eth.src_mac     = 48'hAA_BB_CC_DD_EE_FF;
        pkt.eth.eth_type    = c_TTP_ETHER_TYPE;
        
        pkt.ttp.vci         = truncate(cmd.kid >> 24);
        pkt.ttp.flags       = 8'h00;
        pkt.ttp.rx_seq      = 0;
        pkt.ttp.reserved    = 0;
        pkt.ttp.opcode      = 6'h06; // TTP_PAYLOAD
        pkt.ttp.payload_len = host_data.ttp.payload_len;
        pkt.ttp.tx_seq      = tx_seq;
        
        $display("[TX] send DATA payload_len=%0d tx_seq=%0d", pkt.ttp.payload_len, tx_seq);
        mac_out_q.enq(pkt);
    endrule

    interface noc_tx_in  = toPut(noc_in_q);
    interface mac_tx_out = toGet(mac_out_q);

    method Action generate_ctrl_pkt(Bit#(64) kid, TTPoE_Response rs);
        $display("[TX] enqueue ctrl rs=%0d kid=0x%0h", pack(rs), kid);
        cmd_q.enq(CmdReq { kid: kid, rs: rs });
    endmethod

endmodule
endpackage: TX_Builder