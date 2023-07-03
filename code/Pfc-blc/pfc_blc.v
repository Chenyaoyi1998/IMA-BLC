`timescale 1ns / 1ps
module pfc_blc #(
    parameter DATA_WIDTH=8,
    parameter BPS_L=1,
    parameter BPN_L=100,
    parameter READ_PIXEL=16,
    parameter BPS_R=BPS_L+BPN_L+READ_PIXEL,
    parameter BPN_R=100
) (
    input clk_p,
    input clk_n,
    input rst_n,
    input i_valid,
    input i_ready,
    input [DATA_WIDTH-1:0] idata,
    output reg o_valid,
    output o_ready,
    output reg [DATA_WIDTH-1:0] odata
    );
    
    wire clk;
    IBUFDS RXD_FPGA_diff (
        .I(clk_p),
        .IB(clk_n),
        .O(clk)
    );
    
    reg [15:0] pixel_cnt_r;//指示当前输入的像素的位置
    reg [READ_PIXEL*DATA_WIDTH-1:0] line_buffer_r;//存储有效像素
    reg [11:0] ready_delay_r;//将ready信号打一拍用于将ready整形成上升沿信号
    reg [(BPN_L + BPN_R)*DATA_WIDTH-1:0] black_buffer_r;//缓存暗像素
    
    //指示black_buffer是否满
    reg black_buffer_full_r;
    reg [7:0] black_pixel_cnt_r;
    
    //产生行间复位信号
    wire reset_signal;
    reg o_ready_delay_r;
    reg [4:0] read_pixel_cnt;
    
    //缓存计分板
    reg [(BPN_L + BPN_R - 1):0] counter_r[(BPN_L + BPN_R - 1):0];
    
    //校正值
    reg [DATA_WIDTH-1:0] ref_data;
    
    //指示输入的像素为暗像素还是有效像素
    wire active_pixel_exist;
    wire black_pixel_exist;
    
    //反压信号
    wire ready;
    wire ready_i;
    
    //计分板
    integer i,j,k,m,n;
    reg [(BPN_L + BPN_R - 1):0] counter[(BPN_L + BPN_R - 1):0];
    
    //求和信号acc_signal
    reg [11:0] acc_signal;
    
    //求和
    reg [(BPN_L + BPN_R - 1):0] total_score0[(BPN_L + BPN_R - 1):0];//100*2
    reg [149:0] total_score1[(BPN_L + BPN_R - 1):0];//50*4
    reg [99:0] total_score2[(BPN_L + BPN_R - 1):0];//25*8
    reg [64:0] total_score3[(BPN_L + BPN_R - 1):0];
    reg [41:0] total_score4[(BPN_L + BPN_R - 1):0];
    reg [27:0] total_score5[(BPN_L + BPN_R - 1):0];
    reg [13:0] total_score6[(BPN_L + BPN_R - 1):0];
    reg [7:0] total_score7[(BPN_L + BPN_R - 1):0];
    
    //两个中位数
    wire [DATA_WIDTH-1:0] med0[19:0];
    wire [DATA_WIDTH-1:0] med1[19:0];
    reg [DATA_WIDTH-1:0] med0_r[19:0];
    reg [DATA_WIDTH-1:0] med1_r[19:0];
    reg [DATA_WIDTH-1:0] med2[1:0];
    reg [DATA_WIDTH-1:0] med3[1:0];
    reg [DATA_WIDTH-1:0] med4;
    reg [DATA_WIDTH-1:0] med5;
    
    //全局中值
    reg [DATA_WIDTH-1:0] med_r;
    
    //------------------------------Combination Logic------------------------------//
    //指示输入的像素为暗像素还是有效像素
    assign active_pixel_exist = (pixel_cnt_r >=BPS_L+BPN_L) && (pixel_cnt_r<BPS_R);
    assign black_pixel_exist = ((pixel_cnt_r>=BPS_L) && (pixel_cnt_r<BPS_L+BPN_L)) || ((pixel_cnt_r>=BPS_R) && (pixel_cnt_r<BPS_R+BPN_R));
    
    //反压信号
    assign ready=i_ready&(!o_ready);
    assign ready_i = ready_delay_r[10]&(!ready_delay_r[11]);
    
    //产生行间复位信号
    assign o_ready = read_pixel_cnt == 0;
    assign reset_signal = o_ready & (!o_ready_delay_r);

    //计分板
    always@(*)begin
        for(i=0;i<(BPN_L+BPN_R);i=i+1)
            for(j=0;j<(BPN_L+BPN_R);j=j+1)
                if(black_buffer_r[i*DATA_WIDTH+:DATA_WIDTH]>black_buffer_r[j*DATA_WIDTH+:DATA_WIDTH])
                    counter[i][j]<=1'b1;
                else if(black_buffer_r[i*DATA_WIDTH+:DATA_WIDTH]==black_buffer_r[j*DATA_WIDTH+:DATA_WIDTH])
                    if(i>j)
                        counter[i][j]<=1'b1;
                    else
                        counter[i][j]<=1'b0;
                else
                    counter[i][j]<=1'b0;
    end

    //两个中位数
    genvar t;
    generate
        for(t=0;t<20;t=t+1)begin:loop
            assign med0[t]=(total_score7[t*10+0]==8'd99) ? black_buffer_r[(t*10+0)*DATA_WIDTH+:DATA_WIDTH] : 
                                   (total_score7[t*10+1]==8'd99) ? black_buffer_r[(t*10+1)*DATA_WIDTH+:DATA_WIDTH] : 
                                   (total_score7[t*10+2]==8'd99) ? black_buffer_r[(t*10+2)*DATA_WIDTH+:DATA_WIDTH] :
                                   (total_score7[t*10+3]==8'd99) ? black_buffer_r[(t*10+3)*DATA_WIDTH+:DATA_WIDTH] :
                                   (total_score7[t*10+4]==8'd99) ? black_buffer_r[(t*10+4)*DATA_WIDTH+:DATA_WIDTH] :
                                   (total_score7[t*10+5]==8'd99) ? black_buffer_r[(t*10+5)*DATA_WIDTH+:DATA_WIDTH] :
                                   (total_score7[t*10+6]==8'd99) ? black_buffer_r[(t*10+6)*DATA_WIDTH+:DATA_WIDTH] :
                                   (total_score7[t*10+7]==8'd99) ? black_buffer_r[(t*10+7)*DATA_WIDTH+:DATA_WIDTH] :
                                   (total_score7[t*10+8]==8'd99) ? black_buffer_r[(t*10+8)*DATA_WIDTH+:DATA_WIDTH] :
                                   (total_score7[t*10+9]==8'd99) ? black_buffer_r[(t*10+9)*DATA_WIDTH+:DATA_WIDTH] :0;
             assign med1[t]=(total_score7[t*10+0]==8'd100) ? black_buffer_r[(t*10+0)*DATA_WIDTH+:DATA_WIDTH] : 
                                   (total_score7[t*10+1]==8'd100) ? black_buffer_r[(t*10+1)*DATA_WIDTH+:DATA_WIDTH] : 
                                   (total_score7[t*10+2]==8'd100) ? black_buffer_r[(t*10+2)*DATA_WIDTH+:DATA_WIDTH] :
                                   (total_score7[t*10+3]==8'd100) ? black_buffer_r[(t*10+3)*DATA_WIDTH+:DATA_WIDTH] :
                                   (total_score7[t*10+4]==8'd100) ? black_buffer_r[(t*10+4)*DATA_WIDTH+:DATA_WIDTH] :
                                   (total_score7[t*10+5]==8'd100) ? black_buffer_r[(t*10+5)*DATA_WIDTH+:DATA_WIDTH] :
                                   (total_score7[t*10+6]==8'd100) ? black_buffer_r[(t*10+6)*DATA_WIDTH+:DATA_WIDTH] :
                                   (total_score7[t*10+7]==8'd100) ? black_buffer_r[(t*10+7)*DATA_WIDTH+:DATA_WIDTH] :
                                   (total_score7[t*10+8]==8'd100) ? black_buffer_r[(t*10+8)*DATA_WIDTH+:DATA_WIDTH] :
                                   (total_score7[t*10+9]==8'd100) ? black_buffer_r[(t*10+9)*DATA_WIDTH+:DATA_WIDTH] :0;                                  
        end
    endgenerate
    
    always@(posedge clk or negedge rst_n)begin
        if(!rst_n)begin
            med2[0]<='d0;
            med2[1]<='d0;
            med3[0]<='d0;
            med3[1]<='d0;
        end
        else if(acc_signal[9]) begin
            med2[0]<=med0[0]|med0[1]|med0[2]|med0[3]|med0[4]|med0[5]|med0[6]|med0[7]|med0[8]|med0[9];
            med2[1]<=med0[10]|med0[11]|med0[12]|med0[13]|med0[14]|med0[15]|med0[16]|med0[17]|med0[18]|med0[19];
            med3[0]<=med1[0]|med1[1]|med1[2]|med1[3]|med1[4]|med1[5]|med1[6]|med1[7]|med1[8]|med1[9];
            med3[1]<=med1[10]|med1[11]|med1[12]|med1[13]|med1[14]|med1[15]|med1[16]|med1[17]|med1[18]|med1[19];
        end
    end
    
    always@(posedge clk or negedge rst_n)begin
        if(!rst_n)begin
            med4<='d0;
            med5<='d0;
        end
        else if(acc_signal[10]) begin
            med4<=med2[0]|med2[1];
            med5<=med3[0]|med3[1];
        end
    end
    //------------------------------Timing Logic------------------------------//
    //整形ready信号
    always@(posedge clk or negedge rst_n)begin
        if(!rst_n)
            ready_delay_r <= 'd0;
        else
            ready_delay_r <= {ready_delay_r[10:0],ready};
    end
    
    //指示当前输入的像素的位置
    always@(posedge clk or negedge rst_n)begin
        if(!rst_n)
            pixel_cnt_r <= 'd0;
        else if(pixel_cnt_r == 1 + BPN_L + READ_PIXEL + BPN_R && i_valid)
            pixel_cnt_r <= 'd0;
        else if(i_valid)
            pixel_cnt_r <= pixel_cnt_r + 1;
    end
    
    //缓存有效像素
    always@(posedge clk  or negedge rst_n)begin
        if(!rst_n)
            line_buffer_r <= 'd0;
        else if(i_valid && active_pixel_exist)
            line_buffer_r <= {line_buffer_r[(READ_PIXEL-1)*DATA_WIDTH-1:0],idata};
        else if(ready_i&&(!o_ready))
            line_buffer_r <= line_buffer_r<<DATA_WIDTH;
    end
    
    //指示black_buffrer是否满了，可以进行下一级比较
    always@(posedge clk or negedge rst_n)begin
        if(!rst_n)
            black_pixel_cnt_r <= 'd0;
        else if(black_pixel_cnt_r == (BPN_L + BPN_R - 1) && i_valid)
            black_pixel_cnt_r <= 'd0;
        else if(i_valid && black_pixel_exist)
            black_pixel_cnt_r <= black_pixel_cnt_r + 1;
    end
    
    //black_buffer
    always@(posedge clk or negedge rst_n)begin
        if(!rst_n)begin
            black_buffer_r <= 'd0;
            black_buffer_full_r <= 1'b0;end
        else if(i_valid && black_pixel_exist)begin
            black_buffer_r <= {black_buffer_r[(BPN_L + BPN_R - 1)*DATA_WIDTH-1:0],idata};
            black_buffer_full_r <= black_pixel_cnt_r == (BPN_L + BPN_R - 1);end
        else begin
            black_buffer_r <= black_buffer_r;
            black_buffer_full_r <= 1'b0;end
    end
    
    //缓存计分板
    always@(posedge clk or negedge rst_n)begin
        if(!rst_n)
            for(m=0;m<(BPN_L + BPN_R);m=m+1)
                for(n=0;n<(BPN_L + BPN_R);n=n+1)
                    counter_r[m][n] <= 'd0;
        else if(black_buffer_full_r)
            for(m=0;m<(BPN_L + BPN_R);m=m+1)
                for(n=0;n<(BPN_L + BPN_R);n=n+1)
                    counter_r[m][n] <= counter[m][n];
    end
    
    //求和信号
    always@(posedge clk or negedge rst_n)begin
        if(!rst_n)
            acc_signal <= 'd0;
        else
            acc_signal <= {acc_signal[10:0],black_buffer_full_r};
    end
    
    //求和_0
    integer ii,jj;
    always@(posedge clk or negedge rst_n)begin
        if(!rst_n)
            for(ii=0;ii<(BPN_L+BPN_R);ii=ii+1)
                for(jj=0;jj<(BPN_L+BPN_R)/2;jj=jj+1)
                    total_score0[ii][jj*2+:2]<='d0;
        else if(acc_signal[0])
            for(ii=0;ii<(BPN_L+BPN_R);ii=ii+1)
                for(jj=0;jj<(BPN_L+BPN_R)/2;jj=jj+1)
                    total_score0[ii][jj*2+:2]<=counter_r[ii][jj*2]+counter_r[ii][jj*2+1];
    end
    
    //求和_1
    integer i_1,j_1;
    always@(posedge clk or negedge rst_n)begin
        if(!rst_n)
            for(i_1=0;i_1<(BPN_L+BPN_R);i_1=i_1+1)
                for(j_1=0;j_1<(BPN_L+BPN_R)/4;j_1=j_1+1)
                    total_score1[i_1][j_1*3+:3]<='d0;
        else if(acc_signal[1])
            for(i_1=0;i_1<(BPN_L+BPN_R);i_1=i_1+1)
                for(j_1=0;j_1<(BPN_L+BPN_R)/4;j_1=j_1+1)
                    total_score1[i_1][j_1*3+:3]<=total_score0[i_1][j_1*4+:2]+total_score0[i_1][(j_1*4+2)+:2];
    end
    
    //求和_2
    integer i_2,j_2;
    always@(posedge clk or negedge rst_n)begin
        if(!rst_n)
            for(i_2=0;i_2<(BPN_L+BPN_R);i_2=i_2+1)
                for(j_2=0;j_2<(BPN_L+BPN_R)/8;j_2=j_2+1)
                    total_score2[i_2][j_2*4+:4]<='d0;
        else if(acc_signal[2])
            for(i_2=0;i_2<(BPN_L+BPN_R);i_2=i_2+1)
                for(j_2=0;j_2<(BPN_L+BPN_R)/8;j_2=j_2+1)
                    total_score2[i_2][j_2*4+:4]<=total_score1[i_2][j_2*6+:3]+total_score1[i_2][(j_2*6+3)+:3];
    end
    
    //求和_3
    integer i_3,j_3;
    always@(posedge clk or negedge rst_n)begin
        if(!rst_n)
            for(i_3=0;i_3<(BPN_L+BPN_R);i_3=i_3+1)
                for(j_3=0;j_3<13;j_3=j_3+1)
                    total_score3[i_3][j_3*5+:5]<='d0;
        else if(acc_signal[3])
            for(i_3=0;i_3<(BPN_L+BPN_R);i_3=i_3+1)begin
                for(j_3=0;j_3<12;j_3=j_3+1)
                    total_score3[i_3][j_3*5+:5]<=total_score2[i_3][j_3*8+:4]+total_score2[i_3][(j_3*8+4)+:4];
                total_score3[i_3][60+:5] <= {1'b0,total_score2[i_3][99:96]};
            end
    end
    
    //求和_4
    integer i_4,j_4;
    always@(posedge clk or negedge rst_n)begin
        if(!rst_n)
            for(i_4=0;i_4<(BPN_L+BPN_R);i_4=i_4+1)
                for(j_4=0;j_4<7;j_4=j_4+1)
                    total_score4[i_4][j_4*6+:6]<='d0;
        else if(acc_signal[4])
            for(i_4=0;i_4<(BPN_L+BPN_R);i_4=i_4+1)begin
                for(j_4=0;j_4<6;j_4=j_4+1)
                    total_score4[i_4][j_4*6+:6]<=total_score3[i_4][j_4*10+:5]+total_score3[i_4][(j_4*10+5)+:5];
                total_score4[i_4][36+:6] <= {1'b0,total_score3[i_4][60+:5]};
            end
    end
    
    //求和_5
    integer i_5,j_5;
    always@(posedge clk or negedge rst_n)begin
        if(!rst_n)
            for(i_5=0;i_5<(BPN_L+BPN_R);i_5=i_5+1)
                for(j_5=0;j_5<4;j_5=j_5+1)
                    total_score5[i_5][j_5*7+:7]<='d0;
        else if(acc_signal[5])
            for(i_5=0;i_5<(BPN_L+BPN_R);i_5=i_5+1)begin
                for(j_5=0;j_5<3;j_5=j_5+1)
                    total_score5[i_5][j_5*7+:7]<=total_score4[i_5][j_5*12+:6]+total_score4[i_5][(j_5*12+6)+:6];
                total_score5[i_5][21+:7] <= {1'b0,total_score4[i_5][36+:6]};
            end
    end
    
    //求和_6
    integer i_6,j_6;
    always@(posedge clk or negedge rst_n)begin
        if(!rst_n)
            for(i_6=0;i_6<(BPN_L+BPN_R);i_6=i_6+1)
                for(j_6=0;j_6<2;j_6=j_6+1)
                    total_score6[i_6][j_6*7+:7]<='d0;
        else if(acc_signal[6])
            for(i_6=0;i_6<(BPN_L+BPN_R);i_6=i_6+1)begin
                for(j_6=0;j_6<2;j_6=j_6+1)
                    total_score6[i_6][j_6*7+:7]<=total_score5[i_6][j_6*14+:7]+total_score5[i_6][(j_6*14+7)+:7];
            end
    end
    
    //求和_7
    integer i_7;
    always@(posedge clk or negedge rst_n)begin
        if(!rst_n)
            for(i_7=0;i_7<(BPN_L+BPN_R);i_7=i_7+1)
                    total_score7[i_7]<='d0;
        else if(acc_signal[7])
            for(i_7=0;i_7<(BPN_L+BPN_R);i_7=i_7+1)begin
                    total_score7[i_7]<=total_score6[i_7][6:0]+total_score6[i_7][13:7];
            end
    end
    
    integer w;
    always@(posedge clk or negedge rst_n)begin
        if(!rst_n)
            for(w=0;w<20;w=w+1)begin
                med0_r[w] <= 'd0;
                med1_r[w] <= 'd0;
            end
        else if(acc_signal[8])
            for(w=0;w<20;w=w+1)begin
                med0_r[w] <= med0[w];
                med1_r[w] <= med1[w];
            end
    end
    
    always@(posedge clk or negedge rst_n)begin
        if(!rst_n)
            med_r <= 'd0;
        else if(acc_signal[11])
            med_r <= (med4 + med5) >> 1;
    end
    
    //产生行间复位信号
    always@(posedge clk or negedge rst_n)begin
        if(!rst_n)
            o_ready_delay_r <= 1'b0;
        else
            o_ready_delay_r <= o_ready;
    end
    
    //产生o_ready信号
    always@(posedge clk or negedge rst_n)begin
        if(!rst_n)
            read_pixel_cnt <= 'd0;
        else if(read_pixel_cnt == READ_PIXEL+1)
            read_pixel_cnt <= 1'b0;
        else if(read_pixel_cnt > 0 && ready_i)
            read_pixel_cnt <= read_pixel_cnt + 1;
        else if(acc_signal[0])
            read_pixel_cnt <= 1'b1;
    end
    
    //产生校正后像素值与o_valid信号
    always@(posedge clk or negedge rst_n)begin
        if(!rst_n)begin
            odata <= 'd0;
            o_valid <= 1'b0;
        end
        else if(ready_i&&(!o_ready))begin
            odata <= line_buffer_r[READ_PIXEL*DATA_WIDTH-1:(READ_PIXEL-1)*DATA_WIDTH] - med_r;
            o_valid <= 1'b1;
        end
        else
            o_valid <= 1'b0;
    end
endmodule
