`timescale 1ns / 1ps

module tb_mem_shim;

    reg clk;
    reg rst_n;

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

    // DUT
    mem_shim uut (
        .clk(clk),
        .rst_n(rst_n),
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
        forever #5 clk = ~clk; // 100MHz
    end

    // Test Sequence
    initial begin
        $dumpfile("mem_shim.vcd");
        $dumpvars(0, tb_mem_shim);

        // Initialize Inputs
        rst_n = 0;
        mem_req_rd_cmd = 0;
        mem_req_rd_addr = 0;
        mem_req_rd_dta = 0;
        mem_req_rd_valid = 0;
        mem_res_wr_almost_full = 0;
        ddr3_readdata = 0;
        ddr3_readdatavalid = 0;
        ddr3_waitrequest = 0;

        // Reset
        #20 rst_n = 1;
        #20;

        // Test 1: Simple Write
        $display("Test 1: Simple Write");
        
        // Assert Write Request
        mem_req_rd_cmd = 2'd3; // CMD_WRITE
        mem_req_rd_addr = 22'h123456;
        mem_req_rd_dta = 64'hDEADBEEFCAFEBABE;
        mem_req_rd_valid = 1;

        // Wait for acceptance
        wait(mem_req_rd_en == 0); // FSM should deassert EN when accepting
        @(posedge clk);
        #1; // Wait for combinational logic to settle
        $display("Core Request Accepted");
        
        if (ddr3_write !== 1) $error("DDR3 Write not asserted");
        // Address Check: Expect {4'b0011, 22'h123456, 3'b000}
        // 4'b0011 = 3
        if (ddr3_addr !== {4'b0011, 22'h123456, 3'b000}) $error("DDR3 Address mismatch. Got: %h", ddr3_addr);
        if (ddr3_writedata !== 64'hDEADBEEFCAFEBABE) $error("DDR3 Data mismatch");

        mem_req_rd_valid = 0;
        #20;

        // Test 2: Simple Read
        $display("Test 2: Simple Read");
        
        mem_req_rd_cmd = 2'd2; // CMD_READ
        mem_req_rd_addr = 22'h1BCDEF; 
        mem_req_rd_valid = 1;

        wait(mem_req_rd_en == 0);
        @(posedge clk); 
        #1;
        if (ddr3_read !== 1) $error("DDR3 Read not asserted");
        // Address Check
        if (ddr3_addr !== {4'b0011, 22'h1BCDEF, 3'b000}) $error("DDR3 Address mismatch. Got: %h", ddr3_addr);

        // FSM should still be in WAIT (waitrequest=0) -> IDLE next cycle
        mem_req_rd_valid = 0;
        #20;

        // Simulate Memory Response
        ddr3_readdata = 64'h0123456789ABCDEF;
        ddr3_readdatavalid = 1;
        $display("Time: %t, Setting valid=1", $time);
        @(posedge clk);
        #1; 
        ddr3_readdatavalid = 0;
        
        $display("Time: %t, Checking. en_out=%b, data=%h", $time, mem_res_wr_en, mem_res_wr_dta);
        
        // Check Core Response
        if (mem_res_wr_en !== 1) $error("Core Response not asserted");
        if (mem_res_wr_dta !== 64'h0123456789ABCDEF) $error("Core Response Data mismatch");

        #20;

        // Test 3: Backpressure (Waitrequest)
        $display("Test 3: Backpressure");
        
        ddr3_waitrequest = 1;
        mem_req_rd_cmd = 2'd2; // READ
        mem_req_rd_valid = 1;
        
        // Wait for FIFO accept (en=1 -> en=0)
        // With previous Waitrequest issue, en stayed 1 and read stayed 0.
        // Now read should go 1 and en should go 0.
        wait(mem_req_rd_en == 0);
        
        @(posedge clk);
        #1;
        
        // FSM should have transitioned to WAIT state and asserted READ
        if (ddr3_read !== 1) $error("DDR3 Read not asserted during Waitrequest");
        
        // Check if en became 0 (stall)
        if (mem_req_rd_en !== 0) $display("WARNING: mem_req_rd_en should be 0 in WAIT state. Actual: %b", mem_req_rd_en);
        
        // Release Waitrequest
        @(posedge clk);
        ddr3_waitrequest = 0;
        #1;
        // Should return to IDLE and assert EN (popping)
        if (mem_req_rd_en !== 1) $error("Core Request NOT accepted (en!=1) after Waitrequest release");
        
        @(posedge clk);
        mem_req_rd_valid = 0;

        #100;
        $display("Test Complete");
        $finish;
    end

endmodule
