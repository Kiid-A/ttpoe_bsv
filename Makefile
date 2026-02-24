# ==========================================================
# TTPoE BSV Project Makefile
# ==========================================================

# 1. 定义所有源代码所在的子目录路径
DIR_INC  = src/include
DIR_CORE = src/core
DIR_DATA = src/datapath
DIR_TOP  = src/top

# 2. 拼接为 bsc 的搜索路径 (-p)
BSC_PATH = -p +:$(DIR_INC):$(DIR_CORE):$(DIR_DATA):$(DIR_TOP)

# 3. 顶层测试模块名称和文件路径
TOP_MODULE = mkTb_TTPoE
TEST_FILE  = src/test/Tb_TTPoE.bsv
SIM_EXE    = sim_ttpoe

# 4. 默认目标：编译 -> 链接 -> 运行
all: compile link run

# 编译生成中间文件
compile:
	@echo "=> Compiling BSV files..."
	bsc $(BSC_PATH) -sim -g $(TOP_MODULE) -u $(TEST_FILE)

# 链接生成可执行文件
link:
	@echo "=> Linking..."
	bsc $(BSC_PATH) -sim -e $(TOP_MODULE) -o $(SIM_EXE)

# 运行仿真
run:
	@echo "=> Running Simulation..."
	./$(SIM_EXE)

# 清理产生的中间文件
clean:
	@echo "=> Cleaning up..."
	rm -f *.bo *.ba *.cxx *.h *.o $(SIM_EXE)
