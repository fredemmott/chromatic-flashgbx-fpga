// Byte FIFO with commit/rewind semantics on both ports, for lossy
// packet-oriented streams (USB bulk retries). One instance per direction
// (simplex): TX uses a speculative read port, RX a speculative write port.
//
// Each port is either "speculative" (driven by the USB controller, where a
// packet may need to be retried) or "final" (tie commit_i = 1'b1,
// rewind_i = 1'b0).
//
// - Speculative writes become readable only after wr_commit_i
//   (e.g. rxpktval); wr_rewind_i discards uncommitted writes
//   (e.g. ~rxact) so a retransmitted OUT packet overwrites them.
// - Speculative pops are only consumed after rd_commit_i
//   (e.g. txpktfin); rd_rewind_i un-pops uncommitted pops
//   (e.g. ~txact) so a retried IN packet replays the same bytes.
//
// Rewind is a no-op if the port has no uncommitted operations, so both may
// be driven as levels. Commit takes priority over rewind on the same
// cycle, and a commit includes a write/pop occurring on that same cycle.
//
// This intentionally does not handle corking or optimizing packet sizes, as LK
// needs app-specific logic there; we also need *per-endpoint* reset, which is why
// we can't use the same USB fifo as EP3
module cartio_usb_simplex_fifo #(
    parameter ADDR_WIDTH = 12
)(
    input  wire                clk,
    input  wire                reset,

    // Write port
    input  wire                wr_val_i,
    input  wire [7:0]          wr_data_i,
    input  wire                wr_commit_i,
    input  wire                wr_rewind_i,

    // Read port; rd_data_o is registered and presents the byte at the
    // (resolved) read pointer, i.e. on the cycle rd_pop_i is asserted it
    // holds the byte being popped.
    input  wire                rd_pop_i,
    output logic [7:0]         rd_data_o,
    input  wire                rd_commit_i,
    input  wire                rd_rewind_i,

    // Committed bytes available to read (shrinks with speculative pops,
    // grows back on rd_rewind_i)
    output wire [ADDR_WIDTH:0] count_o,
    // Free space, accounting for uncommitted (speculative) writes
    output wire [ADDR_WIDTH:0] free_o
);
    localparam DEPTH = 1 << ADDR_WIDTH;

    logic [7:0] buffer [DEPTH-1:0];

    // One extra pointer bit disambiguates full vs. empty
    logic [ADDR_WIDTH:0] wr_p;          // speculative write pointer
    logic [ADDR_WIDTH:0] wr_commit_p;   // writes are valid up to here
    logic [ADDR_WIDTH:0] wr_commit_p_d; // ... delayed, see note above
    logic [ADDR_WIDTH:0] rd_p;          // speculative read pointer
    logic [ADDR_WIDTH:0] rd_commit_p;   // pops are consumed up to here

    wire [ADDR_WIDTH:0] wr_p_next = wr_p + (wr_val_i ? 1'd1 : 1'd0);
    wire [ADDR_WIDTH:0] rd_p_next = rd_p + (rd_pop_i ? 1'd1 : 1'd0);

    // Resolved next pointers: commit wins over rewind
    wire [ADDR_WIDTH:0] wr_p_res = wr_commit_i ? wr_p_next :
                                   wr_rewind_i ? wr_commit_p :
                                                 wr_p_next;
    wire [ADDR_WIDTH:0] rd_p_res = rd_commit_i ? rd_p_next :
                                   rd_rewind_i ? rd_commit_p :
                                                 rd_p_next;

    assign count_o    = wr_commit_p_d - rd_p;
    assign free_o     = DEPTH[ADDR_WIDTH:0] - (wr_p - rd_commit_p);

    always @(posedge clk) begin
        rd_data_o <= buffer[rd_p_res[ADDR_WIDTH-1:0]];

        if (reset) begin
            wr_p          <= '0;
            wr_commit_p   <= '0;
            wr_commit_p_d <= '0;
            rd_p          <= '0;
            rd_commit_p   <= '0;
        end else begin
            if (wr_val_i) begin
                buffer[wr_p[ADDR_WIDTH-1:0]] <= wr_data_i;
            end

            wr_p          <= wr_p_res;
            wr_commit_p   <= wr_commit_i ? wr_p_next : wr_commit_p;
            wr_commit_p_d <= wr_commit_p;
            rd_p          <= rd_p_res;
            rd_commit_p   <= rd_commit_i ? rd_p_next : rd_commit_p;
        end
    end
endmodule