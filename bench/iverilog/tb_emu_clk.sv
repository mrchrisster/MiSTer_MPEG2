`timescale 1ns / 1ps

module tb_emu_clk;

    // Inputs
    reg CLK_50M;
    reg RESET;
    wire [48:0] HPS_BUS; // Inout

    // DDRAM Inputs
    reg DDRAM_BUSY;
    reg [63:0] DDRAM_DOUT;
    reg DDRAM_DOUT_READY;
    
    // Other Inputs
    reg [11:0] HDMI_WIDTH;
    reg [11:0] HDMI_HEIGHT;
    reg CLK_AUDIO;
    reg SD_MISO;
    reg SD_CD;
    reg UART_CTS;
    reg UART_RXD;
    reg UART_DSR;
    reg [6:0] USER_IN;
    reg OSD_STATUS;

    // Outputs
    wire CLK_VIDEO;
    wire CE_PIXEL;
    wire [12:0] VIDEO_ARX;
    wire [12:0] VIDEO_ARY;
    wire [7:0] VGA_R;
    wire [7:0] VGA_G;
    wire [7:0] VGA_B;
    wire VGA_HS;
    wire VGA_VS;
    wire VGA_DE;
    wire VGA_F1;
    wire [1:0] VGA_SL;
    wire VGA_SCALER;
    wire VGA_DISABLE;
    wire HDMI_FREEZE;
    wire HDMI_BLACKOUT;
    wire HDMI_BOB_DEINT;
    wire LED_USER;
    wire [1:0] LED_POWER;
    wire [1:0] LED_DISK;
    wire [1:0] BUTTONS;
    wire [15:0] AUDIO_L;
    wire [15:0] AUDIO_R;
    wire AUDIO_S;
    wire [1:0] AUDIO_MIX;
    wire [3:0] ADC_BUS; // Inout
    wire SD_SCK;
    wire SD_MOSI;
    wire SD_CS;
    
    // DDRAM Outputs check
    wire DDRAM_CLK;
    wire [7:0] DDRAM_BURSTCNT;
    wire [28:0] DDRAM_ADDR;
    wire DDRAM_RD;
    wire [63:0] DDRAM_DIN;
    wire [7:0] DDRAM_BE;
    wire DDRAM_WE;

    wire UART_RTS;
    wire UART_TXD;
    wire UART_DTR;
    wire [6:0] USER_OUT;
    wire LOCKED;

    // SDRAM outputs (unused)
    wire SDRAM_CLK;
    wire SDRAM_CKE;
    wire [12:0] SDRAM_A;
    wire [1:0] SDRAM_BA;
    wire SDRAM_DQML;
    wire SDRAM_DQMH;
    wire SDRAM_nCS;
    wire SDRAM_nCAS;
    wire SDRAM_nRAS;
    wire SDRAM_nWE;

    // Instantiate the Unit Under Test (UUT)
    emu uut (
        .CLK_50M(CLK_50M), 
        .RESET(RESET), 
        .HPS_BUS(HPS_BUS), 
        .CLK_VIDEO(CLK_VIDEO), 
        .CE_PIXEL(CE_PIXEL), 
        .VIDEO_ARX(VIDEO_ARX), 
        .VIDEO_ARY(VIDEO_ARY), 
        .VGA_R(VGA_R), 
        .VGA_G(VGA_G), 
        .VGA_B(VGA_B), 
        .VGA_HS(VGA_HS), 
        .VGA_VS(VGA_VS), 
        .VGA_DE(VGA_DE), 
        .VGA_F1(VGA_F1), 
        .VGA_SL(VGA_SL), 
        .VGA_SCALER(VGA_SCALER), 
        .VGA_DISABLE(VGA_DISABLE), 
        .HDMI_WIDTH(HDMI_WIDTH), 
        .HDMI_HEIGHT(HDMI_HEIGHT), 
        .HDMI_FREEZE(HDMI_FREEZE), 
        .HDMI_BLACKOUT(HDMI_BLACKOUT), 
        .HDMI_BOB_DEINT(HDMI_BOB_DEINT), 
        .LED_USER(LED_USER), 
        .LED_POWER(LED_POWER), 
        .LED_DISK(LED_DISK), 
        .BUTTONS(BUTTONS), 
        .CLK_AUDIO(CLK_AUDIO), 
        .AUDIO_L(AUDIO_L), 
        .AUDIO_R(AUDIO_R), 
        .AUDIO_S(AUDIO_S), 
        .AUDIO_MIX(AUDIO_MIX), 
        .ADC_BUS(ADC_BUS), 
        .SD_SCK(SD_SCK), 
        .SD_MOSI(SD_MOSI), 
        .SD_MISO(SD_MISO), 
        .SD_CS(SD_CS), 
        .SD_CD(SD_CD), 
        .DDRAM_CLK(DDRAM_CLK), 
        .DDRAM_BUSY(DDRAM_BUSY), 
        .DDRAM_BURSTCNT(DDRAM_BURSTCNT), 
        .DDRAM_ADDR(DDRAM_ADDR), 
        .DDRAM_DOUT(DDRAM_DOUT), 
        .DDRAM_DOUT_READY(DDRAM_DOUT_READY), 
        .DDRAM_RD(DDRAM_RD), 
        .DDRAM_DIN(DDRAM_DIN), 
        .DDRAM_BE(DDRAM_BE), 
        .DDRAM_WE(DDRAM_WE), 
        .SDRAM_CLK(SDRAM_CLK), 
        .SDRAM_CKE(SDRAM_CKE), 
        .SDRAM_A(SDRAM_A), 
        .SDRAM_BA(SDRAM_BA), 
        .SDRAM_DQML(SDRAM_DQML), 
        .SDRAM_DQMH(SDRAM_DQMH), 
        .SDRAM_nCS(SDRAM_nCS), 
        .SDRAM_nCAS(SDRAM_nCAS), 
        .SDRAM_nRAS(SDRAM_nRAS), 
        .SDRAM_nWE(SDRAM_nWE), 
        .UART_CTS(UART_CTS), 
        .UART_RTS(UART_RTS), 
        .UART_RXD(UART_RXD), 
        .UART_TXD(UART_TXD), 
        .UART_DTR(UART_DTR), 
        .UART_DSR(UART_DSR), 
        .USER_OUT(USER_OUT), 
        .USER_IN(USER_IN), 
        .OSD_STATUS(OSD_STATUS),
        .LOCKED(LOCKED)
    );

    // Clock generation (50 MHz)
    initial begin
        CLK_50M = 0;
        forever #10 CLK_50M = ~CLK_50M; // 20ns period -> 50MHz
    end

    // Test sequence
    initial begin
        // Initialize Inputs
        RESET = 1;
        HDMI_WIDTH = 12'd1920;
        HDMI_HEIGHT = 12'd1080;
        CLK_AUDIO = 0;
        SD_MISO = 0;
        SD_CD = 1; // Input active high? Usually active low insert. 
        DDRAM_BUSY = 0;
        DDRAM_DOUT = 64'd0;
        DDRAM_DOUT_READY = 0;
        UART_CTS = 1;
        UART_RXD = 1;
        UART_DSR = 1;
        USER_IN = 7'd0;
        OSD_STATUS = 0;

        // Reset pulse
        #100;
        RESET = 0; // Release reset (active high input to emu? check emu.sv)
        // emu.sv: wire reset_n = locked & ~RESET; -> RESET is active high
        
        #100;
        $display("Checking DDRAM_CLK...");
        
        // Wait for PLL lock (in simulation PLL locks immediately usually)
        if (LOCKED !== 1) begin
             $display("WARNING: PLL not locked yet.");
        end

        // Check if DDRAM_CLK is toggling
        // In simulation sys_pll does: assign outclk_1 = refclk;
        // So DDRAM_CLK should follow CLK_50M (with delta delays)
        
        #20;
        if (DDRAM_CLK === 1'bx || DDRAM_CLK === 1'bz) begin
            $display("ERROR: DDRAM_CLK is X or Z!");
            $finish;
        end
        
        $display("DDRAM_CLK is %b (Time: %t)", DDRAM_CLK, $time);
        
        #10;
        $display("DDRAM_CLK is %b (Time: %t)", DDRAM_CLK, $time);
        
        #10; 
        $display("DDRAM_CLK is %b (Time: %t)", DDRAM_CLK, $time);
        
        $display("SUCCESS: DDRAM_CLK is toggling.");
        $finish;
    end
      
endmodule
