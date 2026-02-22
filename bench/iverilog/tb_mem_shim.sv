`timescale 1ns / 1ps

module tb_mem_shim;

    reg clk;
    reg rst_n;
    reg hard_rst_n;

    // Core Interface
    reg  [1:0] mem_req_rd_cmd;
    reg [21:0] mem_req_rd_addr;
    reg [63:0] mem_req_rd_dta;
    wire       mem_req_rd_en;
    reg        mem_req_rd_valid;

    wire [63:0] mem_res_wr_dta;
    wire        mem_res_wr_en;
    reg         mem_res_wr_almost_full;

    // DDR3 Interface
    wire [28:0] ddr3_addr;
    wire  [7:0] ddr3_burstcnt;
    wire        ddr3_read;
    wire        ddr3_write;
    wire [63:0] ddr3_writedata;
    wire  [7:0] ddr3_byteenable;
    reg  [63:0] ddr3_readdata;
    reg         ddr3_readdatavalid;
    reg         ddr3_waitrequest;

    // Timeout mechanism (100ms)
    initial begin
        #100000000;
        $display("FATAL ERROR: SIMULATION TIMEOUT REACHED!");
        $display("Outstanding Reads: %d", uut.outstanding_reads);
        $finish;
    end

    // DUT
    mem_shim uut (
        .clk(clk),
        .rst_n(rst_n),
        .hard_rst_n(hard_rst_n),
        .mem_req_rd_cmd(mem_req_rd_cmd),
        .mem_req_rd_addr(mem_req_rd_addr),
        .mem_req_rd_dta(mem_req_rd_dta),
        .mem_req_rd_en(mem_req_rd_en),
        .mem_req_rd_valid(mem_req_rd_valid),
        .mem_res_wr_dta(mem_res_wr_dta),
        .mem_res_wr_en(mem_res_wr_en),
        .mem_res_wr_almost_full(mem_res_wr_almost_full),
        .ddr3_addr(ddr3_addr),
        .ddr3_burstcnt(ddr3_burstcnt),
        .ddr3_read(ddr3_read),
        .ddr3_write(ddr3_write),
        .ddr3_writedata(ddr3_writedata),
        .ddr3_byteenable(ddr3_byteenable),
        .ddr3_readdata(ddr3_readdata),
        .ddr3_readdatavalid(ddr3_readdatavalid),
        .ddr3_waitrequest(ddr3_waitrequest)
    );

    // Clock Generation
    initial begin
        clk = 0;
        forever #4.63 clk = ~clk; 
    end

    // Test Sequence
    initial begin
        $monitor("Time: %20t | State: %b | Req: %d | En: %b | DDR: W:%b R:%b | Pend: %d", 
                 $time, uut.state, mem_req_rd_cmd, mem_req_rd_en,
                 ddr3_write, ddr3_read, uut.outstanding_reads);

        // Initialize
        rst_n = 0;
        hard_rst_n = 0;
        mem_req_rd_cmd = 0;
        mem_req_rd_addr = 0;
        mem_req_rd_dta = 0;
        mem_req_rd_valid = 0;
        mem_res_wr_almost_full = 0;
        ddr3_readdata = 0;
        ddr3_readdatavalid = 0;
        ddr3_waitrequest = 0;
        
        #100;
        rst_n = 1;
        hard_rst_n = 1;
        #100;

        // =========================================================================
        // Test 1: Simple Write
        // =========================================================================
        $display("--- Test 1: Simple Write ---");
        mem_req_rd_cmd = 2'd3;
        mem_req_rd_addr = 22'h123456;
        mem_req_rd_dta = 64'hDEADBEEF;
        mem_req_rd_valid = 1;

        wait(mem_req_rd_en == 0);
        @(posedge clk);
        mem_req_rd_valid = 0;
        #20;
        if (ddr3_write === 1 && ddr3_addr === {7'b0011000, 22'h123456} && ddr3_writedata === 64'hDEADBEEF) begin
            $display("PASS: Write command correctly translated and asserted.");
        end else begin
            $error("FAIL: Write not asserted or mismatched! Addr:%h", ddr3_addr);
        end
        #100;

        // =========================================================================
        // Test 2: Write-After-Read (Deadlock Mitigation Test)
        // =========================================================================
        $display("--- Test 2: Write-After-Read Stall ---");
        
        // 1. Issue READ
        mem_req_rd_cmd = 2'd2;
        mem_req_rd_addr = 22'h555555;
        mem_req_rd_valid = 1;
        wait(mem_req_rd_en == 0);
        @(posedge clk);
        mem_req_rd_valid = 0;
        
        // Wait for FSM to return to IDLE (en goes high)
        wait(mem_req_rd_en == 1);
        @(posedge clk);
        
        // 2. Issue WRITE while read is still pending (no readdatavalid yet)
        $display("Issuing WRITE while READ is pending...");
        mem_req_rd_cmd = 2'd3;
        mem_req_rd_addr = 22'hAAAAAA;
        mem_req_rd_dta = 64'h11112222;
        mem_req_rd_valid = 1;
        
        #100;
        // The FSM must NOT issue ddr3_write. It must NOT assert mem_req_rd_en.
        if (ddr3_write == 1) $error("CRITICAL: Write issued during pending read! AXI deadlock risk!");
        if (mem_req_rd_en == 1) $error("CRITICAL: FSM failed to stall FIFO!");
        
        // 3. Provide Read response
        $display("Providing READ response...");
        #1000;
        ddr3_readdatavalid = 1;
        @(posedge clk);
        ddr3_readdatavalid = 0;
        
        // 4. Trace the recovery
        wait(ddr3_write == 1);
        $display("WRITE resumed successfully.");
        
        // =========================================================================
        // Test 3: Watchdog Reset (Soft Reset) Survival Test
        // =========================================================================
        $display("--- Test 3: Watchdog Reset Survival ---");
        
        // 1. Issue READ
        mem_req_rd_cmd = 2'd2;
        mem_req_rd_addr = 22'h555555;
        mem_req_rd_valid = 1;
        wait(mem_req_rd_en == 0);
        @(posedge clk);
        mem_req_rd_valid = 0;
        
        // Wait for FSM to return to IDLE (en goes high), meaning read was accepted
        wait(mem_req_rd_en == 1);
        @(posedge clk);

        // 2. Trigger Soft Reset (Watchdog firing)
        $display("Triggering Watchdog Reset...");
        rst_n = 0; // Soft reset
        #20;
        rst_n = 1;
        #20;

        // Verify outstanding_reads survived the reset
        if (uut.outstanding_reads != 1) $error("CRITICAL: outstanding_reads was destroyed by watchdog reset!");
        $display("Outstanding Reads survived Watchdog Reset: %d", uut.outstanding_reads);

        // 3. Issue WRITE while read is STILL pending in the bridge
        $display("Issuing WRITE after watchdog recovery...");
        mem_req_rd_cmd = 2'd3;
        mem_req_rd_addr = 22'hBBBBBB;
        mem_req_rd_dta = 64'h99998888;
        mem_req_rd_valid = 1;
        
        #100;
        // The FSM must NOT issue ddr3_write despite being freshly reset.
        if (ddr3_write == 1) $error("CRITICAL: Write issued during pending read! Watchdog reset caused WAR deadlock hazard!");
        
        // 4. Provide Read response from the old read
        $display("Providing READ response from pre-reset...");
        ddr3_readdatavalid = 1;
        @(posedge clk);
        ddr3_readdatavalid = 0;
        
        // 5. Trace the recovery
        wait(ddr3_write == 1);
        $display("WRITE resumed successfully after post-watchdog response.");
        
        #500;
        $display("Simulation Passed.");
        $finish;
    end

endmodule
