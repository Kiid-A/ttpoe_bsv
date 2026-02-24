// =========================================================================
// File: src/testbench/Tb_TTPoE.bsv
// Description: TTPoE 顶层网卡的仿真测试平台 (豪华版验证)
//              涵盖：主动建链 -> 网络响应 -> 主机发数据 -> 网络发数据(旁路测试)
// =========================================================================

package Tb_TTPoE;

import GetPut::*;
import TTPoE_Types::*;
import TTPoE_Headers::*;
import TTPoE_Top::*;

(* synthesize *)
module mkTb_TTPoE(Empty);
    
    // 1. 实例化 DUT (Design Under Test)
    TTPoE_Top_Ifc dut <- mkTTPoE_Top();

    // 2. 全局时钟周期
    Reg#(UInt#(32)) cycle <- mkReg(0);

    // ---------------------------------------------------------------------
    // 测试环境配置与辅助函数
    // ---------------------------------------------------------------------
    // 目标 KID 配置 (对端 MAC 后三字节 11:22:33, VC2)
    TTP_KID test_kid_struct = TTP_KID {
        mac_lsb: 24'h112233,
        vci: 2'b10, 
        is_gw: False, is_ipv4: False, reserved: 0
    };
    Bit#(64) test_kid = pack(test_kid_struct);

    // 额外 KID：用于更多场景 (对端 MAC 后三字节 44:55:66, VC1)
    TTP_KID test_kid2_struct = TTP_KID {
        mac_lsb: 24'h445566,
        vci: 2'b01,
        is_gw: False, is_ipv4: False, reserved: 0
    };
    Bit#(64) test_kid2 = pack(test_kid2_struct);

    // 额外 KID：用于无连接报文场景 (对端 MAC 后三字节 77:88:99, VC0)
    TTP_KID test_kid3_struct = TTP_KID {
        mac_lsb: 24'h778899,
        vci: 2'b00,
        is_gw: False, is_ipv4: False, reserved: 0
    };
    Bit#(64) test_kid3 = pack(test_kid3_struct);

    // 额外 KID：用于 OPEN_NACK 资源耗尽场景 (对端 MAC 后三字节 A1:B2:C3, VC3)
    TTP_KID test_kid4_struct = TTP_KID {
        mac_lsb: 24'hA1B2C3,
        vci: 2'b11,
        is_gw: False, is_ipv4: False, reserved: 0
    };
    Bit#(64) test_kid4 = pack(test_kid4_struct);

    // 辅助函数：快速构造网络端发来的 Raw_MAC_Frame
    function Raw_MAC_Frame build_mock_net_frame(Bit#(6) opcode, Bit#(16) payload_len, Bit#(32) tx_seq, MAC_Addr src_mac, Bit#(2) vci);
        Raw_MAC_Frame frame;
        // 目标是本机，源 MAC 低 24 位用于 RX_Parser 提取 KID
        frame.eth.dst_mac  = 48'hAA_BB_CC_DD_EE_FF; 
        frame.eth.src_mac  = src_mac; 
        frame.eth.eth_type = c_TTP_ETHER_TYPE;

        frame.ttp.opcode   = opcode;
        frame.ttp.vci      = vci;
        frame.ttp.flags    = 0;
        frame.ttp.payload_len = payload_len;
        frame.ttp.tx_seq   = tx_seq;
        frame.ttp.rx_seq   = 0;
        frame.ttp.reserved = 0;
        
        frame.has_payload  = (payload_len > 0);
        return frame;
    endfunction

    // ---------------------------------------------------------------------
    // 统计计数器 (用于验收关键输出)
    // ---------------------------------------------------------------------
    Reg#(UInt#(16)) cnt_open       <- mkReg(0);
    Reg#(UInt#(16)) cnt_open_ack   <- mkReg(0);
    Reg#(UInt#(16)) cnt_open_nack  <- mkReg(0);
    Reg#(UInt#(16)) cnt_payload    <- mkReg(0);
    Reg#(UInt#(16)) cnt_ack        <- mkReg(0);
    Reg#(UInt#(16)) cnt_close      <- mkReg(0);
    Reg#(UInt#(16)) cnt_close_ack  <- mkReg(0);
    Reg#(UInt#(16)) cnt_close_xack <- mkReg(0);
    Reg#(UInt#(16)) cnt_nack_nl    <- mkReg(0);
    Reg#(UInt#(16)) cnt_noc_bypass <- mkReg(0);
    Reg#(Bool)      done           <- mkReg(False);

    // ---------------------------------------------------------------------
    // 时钟推演引擎
    // ---------------------------------------------------------------------
    rule count_cycles;
        cycle <= cycle + 1;
    endrule

    rule finish_check (cycle > 140 && !done);
        done <= True;
        $display("\n========================================================");
        $display("=== [Cycle %0d] Simulation Finished ===", cycle);
        $display("=== Stats: OPEN=%0d OPEN_ACK=%0d OPEN_NACK=%0d PAYLOAD=%0d ACK=%0d CLOSE=%0d CLOSE_ACK=%0d CLOSE_XACK=%0d NACK_NOLINK=%0d NOC_BYPASS=%0d ===",
                 cnt_open, cnt_open_ack, cnt_open_nack, cnt_payload, cnt_ack, cnt_close, cnt_close_ack, cnt_close_xack, cnt_nack_nl, cnt_noc_bypass);
        if (cnt_open == 0)       $display("!!! ERROR: missing OPEN");
        if (cnt_open_ack == 0)   $display("!!! ERROR: missing OPEN_ACK");
        if (cnt_open_nack == 0)  $display("!!! ERROR: missing OPEN_NACK");
        if (cnt_payload == 0)    $display("!!! ERROR: missing PAYLOAD");
        if (cnt_ack == 0)        $display("!!! ERROR: missing ACK");
        if (cnt_close == 0)      $display("!!! ERROR: missing CLOSE");
        if (cnt_close_ack == 0)  $display("!!! ERROR: missing CLOSE_ACK");
        if (cnt_close_xack == 0) $display("!!! ERROR: missing CLOSE_XACK");
        if (cnt_nack_nl == 0)    $display("!!! ERROR: missing NACK_NOLINK");
        if (cnt_noc_bypass == 0) $display("!!! ERROR: missing NOC_BYPASS");
        $display("========================================================\n");
        $finish;
    endrule

    // =====================================================================
    // 剧本注入区 (Stimulus Generators)
    // =====================================================================

    // [场景 1] Cycle 10: 主机请求建立连接 (ST_CLOSED -> ST_OPEN_SENT)
    rule stim_host_open (cycle == 10);
        $display("\n[%4d] [HOST] request OPEN (kid=0x112233)", cycle);
        dut.host_ctrl_request(EventReq { kid: test_kid, event_type: EV_TXQ_TTP_OPEN });
    endrule

    // [场景 2] Cycle 25: 网络端发来 OPEN (测试被动建链，进入 ST_OPEN_RECD)
    rule stim_net_open_kid2 (cycle == 25);
        $display("\n[%4d] [NET] KID2 -> TTP_OPEN (passive open)", cycle);
        Raw_MAC_Frame frame = build_mock_net_frame(6'h00, 0, 0, 48'h00_00_00_44_55_66, 2'b01);
        dut.mac_rx_in.put(frame);
    endrule

    // [场景 3] Cycle 28: 模拟内部资源分配成功 (KID2 分配 Tag)
    rule stim_inq_alloc_tag_kid2 (cycle == 28);
        $display("\n[%4d] [INT] KID2 alloc tag (EV_INQ_ALLOC_TAG)", cycle);
        dut.host_ctrl_request(EventReq { kid: test_kid2, event_type: EV_INQ_ALLOC_TAG });
    endrule

    // [场景 4] Cycle 30: 网络端回复 OPEN_ACK (KID1: ST_OPEN_SENT -> ST_OPEN)
    rule stim_net_open_ack (cycle == 30);
        $display("\n[%4d] [NET] KID1 -> TTP_OPEN_ACK", cycle);
        Raw_MAC_Frame frame = build_mock_net_frame(6'h01, 0, 0, 48'h00_00_00_11_22_33, 2'b10); // Opcode 0x01 = OPEN_ACK
        dut.mac_rx_in.put(frame);
    endrule

    // [场景 5] Cycle 40: KID3 无连接收到数据 (触发 NACK_NOLINK)
    rule stim_no_link_payload (cycle == 40);
        $display("\n[%4d] [ERR] KID3 payload with no link", cycle);
        dut.host_ctrl_request(EventReq { kid: test_kid3, event_type: EV_RXQ_TTP_PAYLOAD });
    endrule

    // [场景 6] Cycle 50: 主机稳态发送 Payload (KID1)
    rule stim_host_payload (cycle == 50);
        $display("\n[%4d] [HOST] KID1 send PAYLOAD", cycle);
        // 1. 把数据载荷推入数据面
        Raw_MAC_Frame host_data = build_mock_net_frame(6'h06, 1024, 0, 48'h00_00_00_11_22_33, 2'b10);
        dut.noc_tx_in.put(host_data);
        // 2. 把控制事件推入控制面
        dut.host_ctrl_request(EventReq { kid: test_kid, event_type: EV_TXQ_TTP_PAYLOAD });
    endrule

    // [场景 6.5] Cycle 60: KID4 发起 OPEN (用于 OPEN_NACK 路径)
    rule stim_net_open_kid4 (cycle == 60);
        $display("\n[%4d] [NET] KID4 -> TTP_OPEN (OPEN_NACK path)", cycle);
        Raw_MAC_Frame frame = build_mock_net_frame(6'h00, 0, 0, 48'h00_00_00_A1_B2_C3, 2'b11);
        dut.mac_rx_in.put(frame);
    endrule

    // [场景 6.6] Cycle 62: KID4 资源不足，触发 OPEN_NACK
    rule stim_inq_no_tag_kid4 (cycle == 62);
        $display("\n[%4d] [INT] KID4 no tag (EV_INQ_NO_TAG)", cycle);
        dut.host_ctrl_request(EventReq { kid: test_kid4, event_type: EV_INQ_NO_TAG });
    endrule

    // [场景 7] Cycle 80: 网络端发来 Payload (KID1)，测试数据面旁路与 ACK
    rule stim_net_payload (cycle == 80);
        $display("\n[%4d] [NET] KID1 -> TTP_PAYLOAD", cycle);
        Raw_MAC_Frame frame = build_mock_net_frame(6'h06, 512, 0, 48'h00_00_00_11_22_33, 2'b10);
        dut.mac_rx_in.put(frame);
    endrule

    // [场景 8] Cycle 95: 主机请求断链 (KID1)
    rule stim_host_close (cycle == 95);
        $display("\n[%4d] [HOST] KID1 request CLOSE", cycle);
        dut.host_ctrl_request(EventReq { kid: test_kid, event_type: EV_TXQ_TTP_CLOSE });
    endrule

    // [场景 9] Cycle 105: 网络端发来 CLOSE (KID1)
    rule stim_net_close (cycle == 105);
        $display("\n[%4d] [NET] KID1 -> TTP_CLOSE", cycle);
        Raw_MAC_Frame frame = build_mock_net_frame(6'h03, 0, 0, 48'h00_00_00_11_22_33, 2'b10);
        dut.mac_rx_in.put(frame);
    endrule


    // =====================================================================
    // 输出监控区 (Monitors)
    // =====================================================================

    // 监控器 1: 物理网卡发送探针 (监听 DUT 发给网络的包)
    rule monitor_mac_tx (!done);
        Raw_MAC_Frame pkt <- dut.mac_tx_out.get();
        $display("[MAC_TX] send frame to Ethernet");
        
        if (pkt.ttp.opcode == 6'h00) begin
            cnt_open <= cnt_open + 1;
            $display("  - type: TTP_OPEN");
        end
        else if (pkt.ttp.opcode == 6'h01) begin
            cnt_open_ack <= cnt_open_ack + 1;
            $display("  - type: TTP_OPEN_ACK");
        end
        else if (pkt.ttp.opcode == 6'h02) begin
            cnt_open_nack <= cnt_open_nack + 1;
            $display("  - type: TTP_OPEN_NACK");
        end
        else if (pkt.ttp.opcode == 6'h06) begin
            cnt_payload <= cnt_payload + 1;
            $display("  - type: TTP_PAYLOAD (len %0d Bytes)", pkt.ttp.payload_len);
        end
        else if (pkt.ttp.opcode == 6'h07) begin
            cnt_ack <= cnt_ack + 1;
            $display("  - type: TTP_ACK");
        end
        else if (pkt.ttp.opcode == 6'h03) begin
            cnt_close <= cnt_close + 1;
            $display("  - type: TTP_CLOSE");
        end
        else if (pkt.ttp.opcode == 6'h04) begin
            cnt_close_ack <= cnt_close_ack + 1;
            $display("  - type: TTP_CLOSE_ACK");
        end
        else if (pkt.ttp.opcode == 6'h05) begin
            cnt_close_xack <= cnt_close_xack + 1;
            $display("  - type: TTP_CLOSE_XACK");
        end
        else if (pkt.ttp.opcode == 6'h09) begin
            cnt_nack_nl <= cnt_nack_nl + 1;
            $display("  - type: TTP_NACK_NOLINK");
        end
        else begin
            $display("  - type: unknown opcode %x", pkt.ttp.opcode);
        end
        
        $display("  - seq: TxID=%0d | RxID=%0d", pkt.ttp.tx_seq, pkt.ttp.rx_seq);
    endrule

    // 监控器 2: NOC 数据旁路探针 (监听 DUT 直接甩给主机的 Payload)
    rule monitor_noc_rx (!done);
        Raw_MAC_Frame pkt <- dut.noc_rx_out.get();
        cnt_noc_bypass <= cnt_noc_bypass + 1;
        $display("[NOC_BYPASS] RX_Parser fast-path payload");
        $display("  - payload_len: %0d Bytes", pkt.ttp.payload_len);
    endrule

endmodule

endpackage: Tb_TTPoE