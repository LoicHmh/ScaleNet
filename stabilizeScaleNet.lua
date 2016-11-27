--[[----------------------------------------------------------------------------
Restore the running_mean and running_var forgotten to save previously
------------------------------------------------------------------------------]]

require 'torch'
require 'cutorch'

--------------------------------------------------------------------------------
-- parse arguments
local cmd = torch.CmdLine()
cmd:text()
cmd:text('train DeepMask or SharpMask')
cmd:text()
cmd:text('Options:')
cmd:option('-rundir', 'exps/', 'experiments directory')
cmd:option('-datadir', 'data/', 'data directory')
cmd:option('-seed', 1, 'manually set RNG seed')
cmd:option('-gpu', 1, 'gpu device')
cmd:option('-nthreads', 2, 'number of threads for DataSampler')
cmd:option('-reload', '', 'reload a network from given directory')
cmd:text()
cmd:text('Training Options:')
cmd:option('-batch', 32, 'training batch size')
cmd:option('-lr', 0, 'learning rate (0 uses default lr schedule)')
cmd:option('-momentum', 0.9, 'momentum')
cmd:option('-wd', 5e-4, 'weight decay')
cmd:option('-maxload', 4000, 'max number of training batches per epoch')
cmd:option('-testmaxload', 500, 'max number of testing batches')
cmd:option('-maxepoch', 300, 'max number of training epochs')
cmd:option('-iSz', 160, 'input size')
cmd:option('-oSz', 56, 'output size')
cmd:option('-gSz', 112, 'ground truth size')
cmd:option('-shift', 16, 'shift jitter allowed')
cmd:option('-scale', .25, 'scale jitter allowed')
cmd:option('-hfreq', 0.5, 'mask/score head sampling frequency')
cmd:option('-scratch', false, 'train DeepMask with randomly initialize weights')
cmd:option('-reloadepoch', 1, 'the starting epoch for reloading')
cmd:text()
cmd:text('SharpMask Options:')
cmd:option('-dm', '', 'path to trained deepmask (if dm, then train SharpMask)')
cmd:option('-km', 32, 'km')
cmd:option('-ks', 32, 'ks')

local config = cmd:parse(arg)

--------------------------------------------------------------------------------
-- various initializations
torch.setdefaulttensortype('torch.FloatTensor')
cutorch.setDevice(config.gpu)
torch.manualSeed(config.seed)
math.randomseed(config.seed)

local trainSm -- flag to train SharpMask (true) or DeepMask (false)
if #config.dm > 0 then
  trainSm = true
  config.hfreq = 0 -- train only mask head
  config.gSz = config.iSz -- in sharpmask, ground-truth has same dim as input
end

paths.dofile('ScaleNet.lua')

--------------------------------------------------------------------------------
-- reload?
local epoch, model
local reloadpath = config.reload
local model = torch.load(string.format(config.reload))
-- config.reload = reloadpath
config.nthreads = confignthreads

--------------------------------------------------------------------------------
-- directory to save log and model
local pathsv = 'scalenet/exp'
-- config.rundir = cmd:string(
--   paths.concat(config.reload=='' and config.rundir or config.reload, pathsv),
--   config,{rundir=true, gpu=true, reload=true, datadir=true, dm=true} --ignore
-- )
config.rundir = paths.concat(config.rundir, pathsv)
print(string.format('| running in directory %s', config.rundir))
os.execute(string.format('mkdir -p %s',config.rundir))

--------------------------------------------------------------------------------
-- network and criterion
-- model = model or nn.ScaleNet(config)
local criterion = nn.DistKLDivCriterion():cuda()

--------------------------------------------------------------------------------
-- initialize data loader
local DataLoader = paths.dofile('ScaleAwareDataLoaderOneThread.lua')
local trainLoader, valLoader = DataLoader.create(config)

--------------------------------------------------------------------------------
-- initialize Trainer (handles training/testing loop)
paths.dofile('TrainerScaleNet.lua')
local trainer = Trainer(model.model, criterion, config)
model.model:cuda()

--------------------------------------------------------------------------------
-- do it
epoch = 80
print('| start stabilization')
trainer:train(epoch, trainLoader)
trainer:test(epoch, valLoader)
local modelsv = {model=model.model:clone('weight', 'bias', 'running_mean',
  'running_var'), config=config}
torch.save(paths.concat('pretrained', 'stabilize', 'model.t7'), modelsv)
