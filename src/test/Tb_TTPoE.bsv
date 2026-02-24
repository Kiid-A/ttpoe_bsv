// =========================================================================
// File: src/testbench/Tb_TTPoE.bsv
// Description: TTPoE 顶层网卡的仿真测试平台 (Testbench)
// =========================================================================

package Tb_TTPoE;

import GetPut::*;
import TTPoE_Types::*;
import TTPoE_Headers::*;
import TTPoE_Top::*;

// =========================================================================
// 顶层测试模块 (无外部接口)
// =========================================================================
(* synthesize *)
module mkTb_TTPoE(Empty);
    
    // 1. 实例化我们要测试的网卡顶层模块 (DUT - Design Under Test)
    TTPoE_Top_Ifc dut <- mkTTPoE_Top();

    // 2. 仿真全局时钟周期计数器
    Reg#(UInt#(32)) cycle <- mkReg(0);

    // 构造一个测试用的目标 KID (模拟与对端 MAC 为 0x112233 的节点建立 VC2 连接)
    TTP_KID test_kid_struct = TTP_KID {
        mac_lsb: 24'h112233,
        vci: 2'b10, // VC 2 (Data Channel)
        is_gw: False,
        is_ipv4: False,
        reserved: 0
    };
    Bit#(64) test_kid = pack(test_kid_struct);

    // =====================================================================
    // 时钟推进与仿真结束控制
    // =====================================================================
    rule count_cycles;
        cycle <= cycle + 1;
        
        // 跑 100 个周期后自动结束仿真
        if (cycle > 100) begin
            $display("\n=== [Cycle %0d] Simulation Finished Successfully ===", cycle);
            $finish;
        end
    endrule

    // =====================================================================
    // 测试用例 1: 主机触发主动建链 (Host initiates Connection)
    // =====================================================================
    rule test_host_open (cycle == 10);
        $display("\n[Cycle %0d] [Host] Application requests to open a new connection to 0x112233...", cycle);
        
        // 构造一个 TXQ__TTP_OPEN 事件，通过主机的寄存器配置接口压入网卡
        EventReq req = EventReq {
            kid: test_kid,
            event_type: EV_TXQ_TTP_OPEN
        };
        dut.host_ctrl_request(req);
    endrule

    // =====================================================================
    // 监控器 (Monitor): 监听网卡向物理以太网发出的报文
    // =====================================================================
    rule monitor_mac_tx;
        // 使用 Get 接口阻塞抓取网卡的发送队列
        Raw_MAC_Frame pkt <- dut.mac_tx_out.get();
        
        $display("\n[Cycle %0d] [Network Monitor] DUT sent a packet to Ethernet MAC!", cycle);
        
        // 打印还原出的以太网和 TTP 头部信息
        $display("      => Dst MAC  : 0x%x", pkt.eth.dst_mac);
        $display("      => VCI      : %0d", pkt.ttp.vci);
        $display("      => Tx Seq   : %0d", pkt.ttp.tx_seq);
        $display("      => Rx Seq   : %0d", pkt.ttp.rx_seq);
        
        // 验证动作码 (Opcode)
        if (pkt.ttp.opcode == 6'h00) begin
            $display("      => SUCCESS: It is a valid [TTP_OPEN] packet!");
        end else begin
            $display("      => ERROR: Unexpected Opcode %x", pkt.ttp.opcode);
        end
    endrule

    // =====================================================================
    // 监控器 (Monitor): 监听网卡发给主机内存的 Payload 数据
    // =====================================================================
    rule monitor_noc_rx;
        Raw_MAC_Frame pkt <- dut.noc_rx_out.get();
        $display("\n[Cycle %0d] [Host Monitor] DUT bypassed a Payload packet directly to NOC/DMA!", cycle);
        $display("      => Data Len : %0d Bytes", pkt.ttp.payload_len);
    endrule

endmodule

endpackage: Tb_TTPoE