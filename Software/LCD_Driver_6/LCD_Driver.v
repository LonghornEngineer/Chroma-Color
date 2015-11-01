module LCD_Driver(

	clock_50,

	dotClock,				//Rising edge pulse that data comes in on
	dotMOSI,					//Dots coming in from video processor
	dotLatch,				//Active high pulse that loads frame onto display
	dotReg0,					//Select which register to write to
	dotReg1,
	dotReg2,
	dotEnable,				//Selects the display for writes (active low, SPI bus
		
	pairECLK,
	pairE2,
	pairE1,
	pairE0,	
	
	pairOCLK,
	pairO2,
	pairO1,
	pairO0,

	backlight_en,
	backlight_pwm
	
);


input clock_50;

input dotClock;
input dotMOSI;
input dotLatch;
input dotReg0;
input dotReg1;
input dotReg2;
input dotEnable;

output pairOCLK;
output pairO2;
output pairO1;
output pairO0;

output pairECLK;
output pairE2;
output pairE1;
output pairE0;

output backlight_en;
output backlight_pwm;

reg [3:0] which_bit = 6;

reg dataEnable = 1'b0;
reg vsync = 1'b0;
reg hsync = 1'b0;
reg backlightControl = 1'b1;
reg lumControl = 1'b1;

reg [5:0] redE = 0;
reg [5:0] greenE = 0;
reg [5:0] blueE = 0;

reg [5:0] redO = 0;
reg [5:0] greenO = 0;
reg [5:0] blueO = 0;

reg [6:0] CLKEdata = 7'b1100011;
reg [6:0] RX2Edata = 7'b0000000;
reg [6:0] RX1Edata = 7'b0000000;
reg [6:0] RX0Edata = 7'b0000000;

reg [6:0] CLKOdata = 7'b1100011;
reg [6:0] RX2Odata = 7'b0000000;
reg [6:0] RX1Odata = 7'b0000000;
reg [6:0] RX0Odata = 7'b0000000;

reg [3:0] byteBitIn = 0;

reg [15:0] vCurrent = 0;				//Which line we're currently on
parameter [15:0] vFront = 22;			//If current V line is more than this, it's not a Vertical Front Porch signal
parameter [15:0] vBack = 1104;		//If current V line is more than this, it's not a Vertical Back Porch signal		
parameter [15:0] vTotal = 1111;		//If current V line equals this, frame done!

reg [15:0] hCurrent = 0;				//Current horizontal position
parameter [15:0] hFront = 37;			//If current H is more than this, it's not a Horizontal Front Porch signal
parameter [15:0] hBack = 998;			//If current H is less than this, it's not a Horizontal Back Porch signal
parameter [15:0] hSync = 1024;		//If current H is more than this, it's the Horizontal Sync Signal
parameter [15:0] hTotal = 1039;		//If current H equals this, line done!

reg [15:0] currentPixel = 0;			//Which 4x4 pixel we are drawing

reg [3:0] shadePixel [0:29] [0:29];

reg [7:0] pixelX = 0;					//Which sub-pixel of a fat pixel we are drawing
reg [7:0] pixelY = 0;					

reg [15:0] pixelYcount = 0;

reg [15:0] startingRaster = 0;		//Where the display should start reading raster memory from
reg [15:0] endingRaster = 4096;		//Where the display should STOP reading memory
reg [15:0] startingBuffer = 4096;	//Where the dots being loaded should be placed

reg [15:0] endingWhite = 200;			//On what line the white fill terminates
reg [15:0] startingV = 300;			//On what line to begin drawing the 128x32 frame. On a 1080 display, this cannot exceed 599 

reg [7:0] pixelSelect = 2;				//Which pixel bank we are on

reg [3:0] shader [0:44] [0:29];

always @*
begin

	  //Even
	  
	  RX2Edata[6] <= dataEnable;
	  RX2Edata[5] <= vsync;
	  RX2Edata[4] <= hsync;	  
	  RX2Edata[3:0] <= blueE[5:2];
	  
	  RX1Edata[6:5] <= blueE[1:0];
	  RX1Edata[4:0] <= greenE[5:1];
	  
	  RX0Edata[0] <= greenE[0];
	  RX0Edata[5:0] <= redE[5:0];	  

	  //Odd

	  RX2Odata[6] <= dataEnable;
	  RX2Odata[5] <= vsync;
	  RX2Odata[4] <= hsync;	  
	  RX2Odata[3:0] <= blueO[5:2];	
	  
	  RX1Odata[6:5] <= blueO[1:0];
	  RX1Odata[4:0] <= greenO[5:1];
	  
	  RX0Odata[0] <= greenO[0];
	  RX0Odata[5:0] <= redO[5:0];
	  
	  backlight_en <= backlightControl;
	  backlight_pwm <= lumControl;
	  
end


always @(posedge bit_clock_out)
begin

	readAddress <= currentPixel;											//Set RAM read port to current pixel
	
	if (which_bit == 0)														//All 7 bits sent?
	begin
	
		which_bit <= 6;														//Reset bit counter and advance H counter

		if (hCurrent == hTotal)													//Line done?
			begin
				hCurrent <= 0;														//Set H counter to 0
		
				if (vCurrent == vTotal)											//Also on last V line?
					begin
						vCurrent <= 0;												//Set V counter to 0
						pixelY <= 0;
						pixelX <= 0;												//Reset this one too, just in case
						currentPixel <= startingRaster;						//Might as well reset this too PUT IN JUMP VECTOR LATER
						pixelYcount <= 0;
					end
				else
					begin
						vCurrent <= vCurrent + 16'h1;									//If not at end of frame, jump to next line
						
						if (vCurrent >= (startingV + vFront))					//Only advance pixels if we're past the starting line for the DMD image					
							begin
								if (pixelY == 14)																	//Did we draw all 15 lines of the pixel?
									begin
										pixelY <= 0;																//Reset the pixelY counter
										pixelYcount <= pixelYcount + 16'h1;										//Increment the total pixel counter (how many virtual DMD lines we've drawn vertically)
									end
								else
									begin
										pixelY <= pixelY + 8'h1;													//Increment pixel line counter										
										currentPixel <= currentPixel - 16'h80;									//Go back 128 bytes in memory so we draw the same color pixels over again										
									end	
							end
					end			
			end
		else
			begin
			
				hCurrent <= hCurrent + 16'h1;																		//Increment H counter
	
				if (dataEnable)
					begin
						if (vCurrent < (endingWhite + vFront))								//White top portion? All white pixels (no shapes) We don't care															
							begin
								redO <= 63;
								greenO <= 63;
								blueO <= 63;							
									
								redE <= 63;
								greenE <= 63;
								blueE <= 63;											
							end
						else																												//Below white portion. Will either be black, or active DMD area
							begin
								if (vCurrent >= (startingV + vFront))															//Only draw if active pixel area (not in horizontal front or back porch)		
									begin	
										if (pixelX == 28)
											begin		
												if (pixelYcount < 32)
												//if (currentPixel < 4096)
													begin
														currentPixel <= currentPixel + 16'h1;
													end
												pixelX <= 0;							
											end
										else
											begin
												if (pixelX == 12)
													begin
														currentPixel <= currentPixel + 16'h1;
													end
												pixelX <= pixelX + 8'h2;		
											end	
										
										if (pixelYcount < 32)
											begin
												//redO <= dataOut[7:5] * shadePixel[pixelY + (pixelSelect * 15)][pixelX][3:0];
												//greenO <= dataOut[4:2] * shadePixel[pixelY + (pixelSelect * 15)][pixelX][3:0];
												//blueO <= (dataOut[1:0] << 1) * shadePixel[pixelY + (pixelSelect * 15)][pixelX][3:0];																		

												redO <= dataOut[7:5] * shader[pixelY + (pixelSelect * 15)][pixelX][3:0];
												greenO <= dataOut[4:2] * shader[pixelY + (pixelSelect * 15)][pixelX][3:0];
												blueO <= (dataOut[1:0] << 1) * shader[pixelY + (pixelSelect * 15)][pixelX][3:0];												
												
												redE <= dataOut[7:5] * shader[pixelY + (pixelSelect * 15)][pixelX + 1][3:0];
												greenE <= dataOut[4:2] * shader[pixelY + (pixelSelect * 15)][pixelX + 1][3:0];
												blueE <= (dataOut[1:0] << 1) * shader[pixelY + (pixelSelect * 15)][pixelX + 1][3:0];		
	
												//redE <= dataOut[7:5] * shadePixel[pixelY + (pixelSelect * 15)][pixelX + 1][3:0];
												//greenE <= dataOut[4:2] * shadePixel[pixelY + (pixelSelect * 15)][pixelX + 1][3:0];
												//blueE <= (dataOut[1:0] << 1) * shadePixel[pixelY + (pixelSelect * 15)][pixelX + 1][3:0];														
											end
										else
											begin
												redO <= 0;
												greenO <= 0;
												blueO <= 0;								
													
												redE <= 0;
												greenE <= 0;
												blueE <= 0;													
											end
										
							
									end
								else
									begin
										redO <= 0;
										greenO <= 0;
										blueO <= 0;								
											
										redE <= 0;
										greenE <= 0;
										blueE <= 0;				
									end					
							end	

			
							end
				else
					begin
						redO <= 0;
						greenO <= 0;
						blueO <= 0;								
							
						redE <= 0;
						greenE <= 0;
						blueE <= 0;					
					end				
			end		
	end
	else
	begin		
		which_bit <= which_bit - 4'h1;						//If not done drawing a pixel, move to the next bit		
	end	

	//Check if Data Enable bit should be set (active high)
	if ((hCurrent > hFront && hCurrent < hBack) && (vCurrent > vFront && vCurrent < vBack))						//Data is only enabled during visible pixels - disabled in H and V porches
		begin
			dataEnable <= 1'b1;
		end
		else
		begin
			dataEnable <= 1'b0;
		end		
	
	//Check if Horizontal Sync bit should be set (active low)
	if (hCurrent >= hSync)													//16 pixels of the H sync bit (active low)
		begin
			hsync <= 1'b0;
		end
		else
		begin
			hsync <= 1'b1;														//Else, the bit is high (inactive)
		end	

				
	//Check if Vertical Sync bit should be set (active low)
	case(vCurrent)																//5 Vertical Sync lines at end of frame, Vertical Sync active low
		1107:
		begin
			vsync <= 1'b0;
		end
		1108:
		begin
			vsync <= 1'b0;
		end
		1109:
		begin
			vsync <= 1'b0;
		end
		1110:
		begin
			vsync <= 1'b0;
		end	
		1111:
		begin
			vsync <= 1'b0;
		end	
		default:
		begin
			vsync <= 1'b1;														//Else, the bit is high (inactive)
		end
	endcase	

end


always @(posedge dotClock)
begin

	if (dotLatch == 0)											//Clocking in data?
		begin
		  
			if (byteBitIn == 8)									//9th clock? Reset bits and move onto next memory position
				begin    
					byteBitIn <= 0;
					writeEnable <= 0;
					writeAddress <=  writeAddress + 16'h1;                                                            
				end
			else
				begin
					dataIn[byteBitIn] <= dotMOSI;                    
					byteBitIn <= byteBitIn + 4'h1;                          
					writeEnable <= 1;                                  
				end			

		end
		
	else																//Data latch is ACTIVE HIGH
		begin
			byteBitIn <= 0;
			writeEnable <= 0;
			if (startingRaster == 0)							//Flip the draw and fill buffers
				begin
					startingRaster <= 4096;
					endingRaster <= 8192;
					writeAddress <= 0;				
				end
			else
				begin
					startingRaster <= 0;
					endingRaster <= 4096;
					writeAddress <= 4096;				
				end
		end
	
end


assign pairOCLK =        CLKOdata[which_bit];
assign pairO2 =          RX2Odata[which_bit];
assign pairO1 =          RX1Odata[which_bit];
assign pairO0 =          RX0Odata[which_bit];

assign pairECLK =        CLKEdata[which_bit];
assign pairE2 =          RX2Edata[which_bit];
assign pairE1 =          RX1Edata[which_bit];
assign pairE0 =          RX0Edata[which_bit];

bit_clock u1 (

	.inclk0(clock_50),
	.c0(bit_clock_out)
);

RAM2port  u2 (
	.clock(bit_clock_out),
	.data(dataIn),
	.rdaddress(readAddress),
	.wraddress(writeAddress),
	.wren(writeEnable),
	.q(dataOut)
	);

	reg	[7:0]   dataIn;
	reg	[15:0]  readAddress;
	reg	[15:0]  writeAddress;
	reg	writeEnable = 0;
	wire	[7:0]  dataOut;
	
initial
begin

	shader = 
	'{
	
	
	
	//Round Circle, Shaded Edges
	
	'{4'h0, 4'h0, 4'h0, 4'h0, 4'h0, 4'h5, 4'h5, 4'h5, 4'h5, 4'h0, 4'h0, 4'h0, 4'h0, 4'h0, 4'h0,		 4'h0, 4'h0, 4'h0, 4'h0, 4'h0, 4'h5, 4'h5, 4'h5, 4'h5, 4'h0, 4'h0, 4'h0, 4'h0, 4'h0, 4'h0},
	'{4'h0, 4'h0, 4'h0, 4'h5, 4'h5, 4'h9, 4'h9, 4'h9, 4'h9, 4'h5, 4'h5, 4'h0, 4'h0, 4'h0, 4'h0,		 4'h0, 4'h0, 4'h0, 4'h5, 4'h5, 4'h9, 4'h9, 4'h9, 4'h9, 4'h5, 4'h5, 4'h0, 4'h0, 4'h0, 4'h0},
	'{4'h0, 4'h0, 4'h5, 4'h9, 4'h9, 4'h9, 4'h9, 4'h9, 4'h9, 4'h9, 4'h9, 4'h5, 4'h0, 4'h0, 4'h0,		 4'h0, 4'h0, 4'h5, 4'h9, 4'h9, 4'h9, 4'h9, 4'h9, 4'h9, 4'h9, 4'h9, 4'h5, 4'h0, 4'h0, 4'h0},
	'{4'h0, 4'h5, 4'h9, 4'h9, 4'h9, 4'h9, 4'h9, 4'h9, 4'h9, 4'h9, 4'h9, 4'h9, 4'h5, 4'h0, 4'h0,		 4'h0, 4'h5, 4'h9, 4'h9, 4'h9, 4'h9, 4'h9, 4'h9, 4'h9, 4'h9, 4'h9, 4'h9, 4'h5, 4'h0, 4'h0},
	'{4'h0, 4'h5, 4'h9, 4'h9, 4'h9, 4'h9, 4'h9, 4'h9, 4'h9, 4'h9, 4'h9, 4'h9, 4'h5, 4'h0, 4'h0,		 4'h0, 4'h5, 4'h9, 4'h9, 4'h9, 4'h9, 4'h9, 4'h9, 4'h9, 4'h9, 4'h9, 4'h9, 4'h5, 4'h0, 4'h0},
	'{4'h5, 4'h9, 4'h9, 4'h9, 4'h9, 4'h9, 4'h9, 4'h9, 4'h9, 4'h9, 4'h9, 4'h9, 4'h9, 4'h5, 4'h0,		 4'h5, 4'h9, 4'h9, 4'h9, 4'h9, 4'h9, 4'h9, 4'h9, 4'h9, 4'h9, 4'h9, 4'h9, 4'h9, 4'h5, 4'h0},
	'{4'h5, 4'h9, 4'h9, 4'h9, 4'h9, 4'h9, 4'h9, 4'h9, 4'h9, 4'h9, 4'h9, 4'h9, 4'h9, 4'h5, 4'h0,		 4'h5, 4'h9, 4'h9, 4'h9, 4'h9, 4'h9, 4'h9, 4'h9, 4'h9, 4'h9, 4'h9, 4'h9, 4'h9, 4'h5, 4'h0},
	'{4'h5, 4'h9, 4'h9, 4'h9, 4'h9, 4'h9, 4'h9, 4'h9, 4'h9, 4'h9, 4'h9, 4'h9, 4'h9, 4'h5, 4'h0,		 4'h5, 4'h9, 4'h9, 4'h9, 4'h9, 4'h9, 4'h9, 4'h9, 4'h9, 4'h9, 4'h9, 4'h9, 4'h9, 4'h5, 4'h0},
	'{4'h5, 4'h9, 4'h9, 4'h9, 4'h9, 4'h9, 4'h9, 4'h9, 4'h9, 4'h9, 4'h9, 4'h9, 4'h9, 4'h5, 4'h0,		 4'h5, 4'h9, 4'h9, 4'h9, 4'h9, 4'h9, 4'h9, 4'h9, 4'h9, 4'h9, 4'h9, 4'h9, 4'h9, 4'h5, 4'h0},
	'{4'h0, 4'h5, 4'h9, 4'h9, 4'h9, 4'h9, 4'h9, 4'h9, 4'h9, 4'h9, 4'h9, 4'h9, 4'h5, 4'h0, 4'h0,		 4'h0, 4'h5, 4'h9, 4'h9, 4'h9, 4'h9, 4'h9, 4'h9, 4'h9, 4'h9, 4'h9, 4'h9, 4'h5, 4'h0, 4'h0},
	'{4'h0, 4'h5, 4'h9, 4'h9, 4'h9, 4'h9, 4'h9, 4'h9, 4'h9, 4'h9, 4'h9, 4'h9, 4'h5, 4'h0, 4'h0,		 4'h0, 4'h5, 4'h9, 4'h9, 4'h9, 4'h9, 4'h9, 4'h9, 4'h9, 4'h9, 4'h9, 4'h9, 4'h5, 4'h0, 4'h0},
	'{4'h0, 4'h0, 4'h5, 4'h9, 4'h9, 4'h9, 4'h9, 4'h9, 4'h9, 4'h9, 4'h9, 4'h5, 4'h0, 4'h0, 4'h0,		 4'h0, 4'h0, 4'h5, 4'h9, 4'h9, 4'h9, 4'h9, 4'h9, 4'h9, 4'h9, 4'h9, 4'h5, 4'h0, 4'h0, 4'h0},
	'{4'h0, 4'h0, 4'h0, 4'h5, 4'h5, 4'h9, 4'h9, 4'h9, 4'h9, 4'h5, 4'h5, 4'h0, 4'h0, 4'h0, 4'h0,		 4'h0, 4'h0, 4'h0, 4'h5, 4'h5, 4'h9, 4'h9, 4'h9, 4'h9, 4'h5, 4'h5, 4'h0, 4'h0, 4'h0, 4'h0},
	'{4'h0, 4'h0, 4'h0, 4'h0, 4'h0, 4'h5, 4'h5, 4'h5, 4'h5, 4'h0, 4'h0, 4'h0, 4'h0, 4'h0, 4'h0,		 4'h0, 4'h0, 4'h0, 4'h0, 4'h0, 4'h5, 4'h5, 4'h5, 4'h5, 4'h0, 4'h0, 4'h0, 4'h0, 4'h0, 4'h0},
	'{4'h0, 4'h0, 4'h0, 4'h0, 4'h0, 4'h0, 4'h0, 4'h0, 4'h0, 4'h0, 4'h0, 4'h0, 4'h0, 4'h0, 4'h0,		 4'h0, 4'h0, 4'h0, 4'h0, 4'h0, 4'h0, 4'h0, 4'h0, 4'h0, 4'h0, 4'h0, 4'h0, 4'h0, 4'h0, 4'h0},	
	
	//Shaded Tiles
	
	'{4'h0, 4'h5, 4'h5, 4'h5, 4'h5, 4'h5, 4'h5, 4'h5, 4'h5, 4'h5, 4'h5, 4'h5, 4'h5, 4'h0, 4'h0,		 4'h0, 4'h5, 4'h5, 4'h5, 4'h5, 4'h5, 4'h5, 4'h5, 4'h5, 4'h5, 4'h5, 4'h5, 4'h5, 4'h0, 4'h0},
	'{4'h5, 4'h9, 4'h9, 4'h9, 4'h9, 4'h9, 4'h9, 4'h9, 4'h9, 4'h9, 4'h9, 4'h9, 4'h9, 4'h5, 4'h0,		 4'h5, 4'h9, 4'h9, 4'h9, 4'h9, 4'h9, 4'h9, 4'h9, 4'h9, 4'h9, 4'h9, 4'h9, 4'h9, 4'h5, 4'h0},
	'{4'h5, 4'h9, 4'h9, 4'h9, 4'h9, 4'h9, 4'h9, 4'h9, 4'h9, 4'h9, 4'h9, 4'h9, 4'h9, 4'h5, 4'h0,		 4'h5, 4'h9, 4'h9, 4'h9, 4'h9, 4'h9, 4'h9, 4'h9, 4'h9, 4'h9, 4'h9, 4'h9, 4'h9, 4'h5, 4'h0},
	'{4'h5, 4'h9, 4'h9, 4'h9, 4'h9, 4'h9, 4'h9, 4'h9, 4'h9, 4'h9, 4'h9, 4'h9, 4'h9, 4'h5, 4'h0,		 4'h5, 4'h9, 4'h9, 4'h9, 4'h9, 4'h9, 4'h9, 4'h9, 4'h9, 4'h9, 4'h9, 4'h9, 4'h9, 4'h5, 4'h0},
	'{4'h5, 4'h9, 4'h9, 4'h9, 4'h9, 4'h9, 4'h9, 4'h9, 4'h9, 4'h9, 4'h9, 4'h9, 4'h9, 4'h5, 4'h0,		 4'h5, 4'h9, 4'h9, 4'h9, 4'h9, 4'h9, 4'h9, 4'h9, 4'h9, 4'h9, 4'h9, 4'h9, 4'h9, 4'h5, 4'h0},
	'{4'h5, 4'h9, 4'h9, 4'h9, 4'h9, 4'h9, 4'h9, 4'h9, 4'h9, 4'h9, 4'h9, 4'h9, 4'h9, 4'h5, 4'h0,		 4'h5, 4'h9, 4'h9, 4'h9, 4'h9, 4'h9, 4'h9, 4'h9, 4'h9, 4'h9, 4'h9, 4'h9, 4'h9, 4'h5, 4'h0},
	'{4'h5, 4'h9, 4'h9, 4'h9, 4'h9, 4'h9, 4'h9, 4'h9, 4'h9, 4'h9, 4'h9, 4'h9, 4'h9, 4'h5, 4'h0,		 4'h5, 4'h9, 4'h9, 4'h9, 4'h9, 4'h9, 4'h9, 4'h9, 4'h9, 4'h9, 4'h9, 4'h9, 4'h9, 4'h5, 4'h0},
	'{4'h5, 4'h9, 4'h9, 4'h9, 4'h9, 4'h9, 4'h9, 4'h9, 4'h9, 4'h9, 4'h9, 4'h9, 4'h9, 4'h5, 4'h0,		 4'h5, 4'h9, 4'h9, 4'h9, 4'h9, 4'h9, 4'h9, 4'h9, 4'h9, 4'h9, 4'h9, 4'h9, 4'h9, 4'h5, 4'h0},
	'{4'h5, 4'h9, 4'h9, 4'h9, 4'h9, 4'h9, 4'h9, 4'h9, 4'h9, 4'h9, 4'h9, 4'h9, 4'h9, 4'h5, 4'h0,		 4'h5, 4'h9, 4'h9, 4'h9, 4'h9, 4'h9, 4'h9, 4'h9, 4'h9, 4'h9, 4'h9, 4'h9, 4'h9, 4'h5, 4'h0},
	'{4'h5, 4'h9, 4'h9, 4'h9, 4'h9, 4'h9, 4'h9, 4'h9, 4'h9, 4'h9, 4'h9, 4'h9, 4'h9, 4'h5, 4'h0,		 4'h5, 4'h9, 4'h9, 4'h9, 4'h9, 4'h9, 4'h9, 4'h9, 4'h9, 4'h9, 4'h9, 4'h9, 4'h9, 4'h5, 4'h0},
	'{4'h5, 4'h9, 4'h9, 4'h9, 4'h9, 4'h9, 4'h9, 4'h9, 4'h9, 4'h9, 4'h9, 4'h9, 4'h9, 4'h5, 4'h0,		 4'h5, 4'h9, 4'h9, 4'h9, 4'h9, 4'h9, 4'h9, 4'h9, 4'h9, 4'h9, 4'h9, 4'h9, 4'h9, 4'h5, 4'h0},
	'{4'h5, 4'h9, 4'h9, 4'h9, 4'h9, 4'h9, 4'h9, 4'h9, 4'h9, 4'h9, 4'h9, 4'h9, 4'h9, 4'h5, 4'h0,		 4'h5, 4'h9, 4'h9, 4'h9, 4'h9, 4'h9, 4'h9, 4'h9, 4'h9, 4'h9, 4'h9, 4'h9, 4'h9, 4'h5, 4'h0},
	'{4'h5, 4'h9, 4'h9, 4'h9, 4'h9, 4'h9, 4'h9, 4'h9, 4'h9, 4'h9, 4'h9, 4'h9, 4'h9, 4'h5, 4'h0,		 4'h5, 4'h9, 4'h9, 4'h9, 4'h9, 4'h9, 4'h9, 4'h9, 4'h9, 4'h9, 4'h9, 4'h9, 4'h9, 4'h5, 4'h0},
	'{4'h0, 4'h5, 4'h5, 4'h5, 4'h5, 4'h5, 4'h5, 4'h5, 4'h5, 4'h5, 4'h5, 4'h5, 4'h5, 4'h0, 4'h0,		 4'h0, 4'h5, 4'h5, 4'h5, 4'h5, 4'h5, 4'h5, 4'h5, 4'h5, 4'h5, 4'h5, 4'h5, 4'h5, 4'h0, 4'h0},
	'{4'h0, 4'h0, 4'h0, 4'h0, 4'h0, 4'h0, 4'h0, 4'h0, 4'h0, 4'h0, 4'h0, 4'h0, 4'h0, 4'h0, 4'h0,		 4'h0, 4'h0, 4'h0, 4'h0, 4'h0, 4'h0, 4'h0, 4'h0, 4'h0, 4'h0, 4'h0, 4'h0, 4'h0, 4'h0, 4'h0},		
	
	//Super Shaded Circle	
	
	'{4'h0, 4'h0, 4'h0, 4'h0, 4'h0, 4'h3, 4'h3, 4'h3, 4'h3, 4'h0, 4'h0, 4'h0, 4'h0, 4'h0, 4'h0,		 4'h0, 4'h0, 4'h0, 4'h0, 4'h0, 4'h3, 4'h3, 4'h3, 4'h3, 4'h0, 4'h0, 4'h0, 4'h0, 4'h0, 4'h0},
	'{4'h0, 4'h0, 4'h0, 4'h3, 4'h3, 4'h4, 4'h4, 4'h4, 4'h4, 4'h3, 4'h3, 4'h0, 4'h0, 4'h0, 4'h0,		 4'h0, 4'h0, 4'h0, 4'h3, 4'h3, 4'h4, 4'h4, 4'h4, 4'h4, 4'h3, 4'h3, 4'h0, 4'h0, 4'h0, 4'h0},
	'{4'h0, 4'h0, 4'h3, 4'h4, 4'h4, 4'h5, 4'h5, 4'h5, 4'h5, 4'h4, 4'h4, 4'h3, 4'h0, 4'h0, 4'h0,		 4'h0, 4'h0, 4'h3, 4'h4, 4'h4, 4'h5, 4'h5, 4'h5, 4'h5, 4'h4, 4'h4, 4'h3, 4'h0, 4'h0, 4'h0},
	'{4'h0, 4'h3, 4'h4, 4'h5, 4'h5, 4'h6, 4'h6, 4'h6, 4'h6, 4'h5, 4'h5, 4'h4, 4'h3, 4'h0, 4'h0,		 4'h0, 4'h3, 4'h4, 4'h5, 4'h5, 4'h6, 4'h6, 4'h6, 4'h6, 4'h5, 4'h5, 4'h4, 4'h3, 4'h0, 4'h0},
	'{4'h0, 4'h3, 4'h4, 4'h6, 4'h6, 4'h7, 4'h7, 4'h7, 4'h7, 4'h6, 4'h6, 4'h4, 4'h3, 4'h0, 4'h0,		 4'h0, 4'h3, 4'h4, 4'h6, 4'h6, 4'h7, 4'h7, 4'h7, 4'h7, 4'h6, 4'h6, 4'h4, 4'h3, 4'h0, 4'h0},
	
	'{4'h3, 4'h4, 4'h5, 4'h6, 4'h7, 4'h8, 4'h8, 4'h8, 4'h8, 4'h7, 4'h6, 4'h5, 4'h4, 4'h3, 4'h0,		 4'h3, 4'h4, 4'h5, 4'h6, 4'h7, 4'h8, 4'h8, 4'h8, 4'h8, 4'h7, 4'h6, 4'h5, 4'h4, 4'h3, 4'h0},
	'{4'h3, 4'h4, 4'h5, 4'h6, 4'h7, 4'h8, 4'h9, 4'h9, 4'h8, 4'h7, 4'h6, 4'h5, 4'h4, 4'h3, 4'h0,		 4'h3, 4'h4, 4'h5, 4'h6, 4'h7, 4'h8, 4'h9, 4'h9, 4'h8, 4'h7, 4'h6, 4'h5, 4'h4, 4'h3, 4'h0},
	'{4'h3, 4'h4, 4'h5, 4'h6, 4'h7, 4'h8, 4'h9, 4'h9, 4'h8, 4'h7, 4'h6, 4'h5, 4'h4, 4'h3, 4'h0,		 4'h3, 4'h4, 4'h5, 4'h6, 4'h7, 4'h8, 4'h9, 4'h9, 4'h8, 4'h7, 4'h6, 4'h5, 4'h4, 4'h3, 4'h0},
	'{4'h3, 4'h4, 4'h5, 4'h6, 4'h7, 4'h8, 4'h8, 4'h8, 4'h8, 4'h7, 4'h6, 4'h5, 4'h4, 4'h3, 4'h0,		 4'h3, 4'h4, 4'h5, 4'h6, 4'h7, 4'h8, 4'h8, 4'h8, 4'h8, 4'h7, 4'h6, 4'h5, 4'h4, 4'h3, 4'h0},	
	
	'{4'h0, 4'h3, 4'h4, 4'h6, 4'h6, 4'h7, 4'h7, 4'h7, 4'h7, 4'h6, 4'h6, 4'h4, 4'h3, 4'h0, 4'h0,		 4'h0, 4'h3, 4'h4, 4'h6, 4'h6, 4'h7, 4'h7, 4'h7, 4'h7, 4'h6, 4'h6, 4'h4, 4'h3, 4'h0, 4'h0},
	'{4'h0, 4'h3, 4'h4, 4'h5, 4'h5, 4'h6, 4'h6, 4'h6, 4'h6, 4'h5, 4'h5, 4'h4, 4'h3, 4'h0, 4'h0,		 4'h0, 4'h3, 4'h4, 4'h5, 4'h5, 4'h6, 4'h6, 4'h6, 4'h6, 4'h5, 4'h5, 4'h4, 4'h3, 4'h0, 4'h0},
	'{4'h0, 4'h0, 4'h3, 4'h4, 4'h4, 4'h5, 4'h5, 4'h5, 4'h5, 4'h4, 4'h4, 4'h3, 4'h0, 4'h0, 4'h0,		 4'h0, 4'h0, 4'h3, 4'h4, 4'h4, 4'h5, 4'h5, 4'h5, 4'h5, 4'h4, 4'h4, 4'h3, 4'h0, 4'h0, 4'h0},
	'{4'h0, 4'h0, 4'h0, 4'h3, 4'h3, 4'h4, 4'h4, 4'h4, 4'h4, 4'h3, 4'h3, 4'h0, 4'h0, 4'h0, 4'h0,		 4'h0, 4'h0, 4'h0, 4'h3, 4'h3, 4'h4, 4'h4, 4'h4, 4'h4, 4'h3, 4'h3, 4'h0, 4'h0, 4'h0, 4'h0},
	'{4'h0, 4'h0, 4'h0, 4'h0, 4'h0, 4'h3, 4'h3, 4'h3, 4'h3, 4'h0, 4'h0, 4'h0, 4'h0, 4'h0, 4'h0,		 4'h0, 4'h0, 4'h0, 4'h0, 4'h0, 4'h3, 4'h3, 4'h3, 4'h3, 4'h0, 4'h0, 4'h0, 4'h0, 4'h0, 4'h0},
	
	'{4'h0, 4'h0, 4'h0, 4'h0, 4'h0, 4'h0, 4'h0, 4'h0, 4'h0, 4'h0, 4'h0, 4'h0, 4'h0, 4'h0, 4'h0,		 4'h0, 4'h0, 4'h0, 4'h0, 4'h0, 4'h0, 4'h0, 4'h0, 4'h0, 4'h0, 4'h0, 4'h0, 4'h0, 4'h0, 4'h0}
	

	};

end
	
	
	
endmodule


/*

	if (which_bit == 0)														//All 7 bits sent?
	begin
	
		which_bit <= 6;														//Reset bit counter and advance H counter

		if (hCurrent == hTotal)													//Line done?
			begin
				hCurrent <= 0;														//Set H counter to 0
		
				if (vCurrent == vTotal)											//Also on last V line?
					begin
						vCurrent <= 0;													//Set V counter to 0
						pixelY <= 0;
						pixelX <= 0;													//Reset this one too, just in case
						currentPixel <= 0;											//Might as well reset this too PUT IN JUMP VECTOR LATER
					end
				else
				begin
					vCurrent <= vCurrent + 1;									//If not at end of frame, jump to next line
					
						if (vCurrent > vFront)
						
							begin
								if (pixelY == 14)
									begin
										pixelY <= 0;
										currentPixel <= currentPixel;
									end
								else
									begin
										pixelY <= pixelY + 1;
										currentPixel <= currentPixel - 128;
									end					
							end
							
				end
				
			end
		else
			begin
			
				hCurrent <= hCurrent + 1;										//Increment H counter
					
				if (dataEnable)				
					begin
						if (pixelX == 28 && currentPixel < 4096)
							begin
								pixelX <= 0;
								currentPixel <= currentPixel + 2;
							end
						else
							begin
								pixelX <= pixelX + 2;
								currentPixel <= currentPixel;
							end
					

						if (pixelX == 14)
							begin
								redO <= dataOut[7:5] * shadePixel[pixelY][pixelX][3:0];
								greenO <= dataOut[4:2] * shadePixel[pixelY][pixelX][3:0];
								blueO <= (dataOut[1:0] << 1) * shadePixel[pixelY][pixelX][3:0];	
						
								redE <= dataOut[7:5] * shadePixel[pixelY][pixelX + 1][3:0];
								greenE <= dataOut[4:2] * shadePixel[pixelY][pixelX + 1][3:0];
								blueE <= (dataOut[1:0] << 1) * shadePixel[pixelY][pixelX + 1][3:0];							
							end
						else
							begin
								redO <= dataOut[7:5] * shadePixel[pixelY][pixelX][3:0];
								greenO <= dataOut[4:2] * shadePixel[pixelY][pixelX][3:0];
								blueO <= (dataOut[1:0] << 1) * shadePixel[pixelY][pixelX][3:0];	
						
								redE <= dataOut[7:5] * shadePixel[pixelY][pixelX + 1][3:0];
								greenE <= dataOut[4:2] * shadePixel[pixelY][pixelX + 1][3:0];
								blueE <= (dataOut[1:0] << 1) * shadePixel[pixelY][pixelX + 1][3:0];								
							end
			
					end
				else
					begin
						redO <= 0;
						greenO <= 0;
						blueO <= 0;		
						redE <= 0;
						greenE <= 0;
						blueE <= 0;

						pixelX <= 0;
						
					end				
		
			end	
		
	end
	else
	begin
	
		which_bit <= which_bit - 1;						//If not done drawing a pixel, move to the next bit	
	
	end
	
	
*/

