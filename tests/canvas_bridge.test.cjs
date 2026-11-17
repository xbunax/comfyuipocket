const test = require('node:test');
const assert = require('node:assert/strict');
const { executionNode, applyPrompt, ports, connect, disconnect } = require('../ios/Pocket/CanvasBridge.js');
const { setNodeAppearance } = require('../ios/Pocket/CanvasBridge.js');
const { workspaceRestored, loadWorkflowGraph } = require('../ios/Pocket/CanvasBridge.js');

test('graph loading retries a displaced restore and verifies identity before applying inputs', async () => {
  const workflow = {id:'minimax',nodes:[{id:36,type:'Sampler'}]};
  const app = {rootGraph:{id:'qwen',_nodes:[{id:36,type:'Other'}]}, async loadGraphData(graph) {
    this.loads=(this.loads||0)+1;
    if(this.loads===2)this.rootGraph={id:graph.id,_nodes:graph.nodes};
  }};
  await loadWorkflowGraph(app,workflow,'MiniMax');
  assert.equal(app.loads,2);assert.equal(app.rootGraph.id,'minimax');
  assert.equal(workflow.nodes[0].type,'Sampler');
  app.loadGraphData=async()=>{app.rootGraph={id:'qwen',_nodes:[]};};
  await assert.rejects(loadWorkflowGraph(app,workflow,'MiniMax'),/切换了当前画布/);
});

test('wrong workflow and reused IDs cannot receive another workflow parameters', async () => {
  const f=fixture();f.source.type='Other';
  f.app.graphToPrompt=async()=>({output:{'1':{class_type:'Other',inputs:{width:512}}}});
  const prompt={'1':{class_type:'Source',inputs:{width:1024}}};
  assert.deepEqual(await applyPrompt(f.app,prompt),['1.class_type']);
  assert.equal(f.source.widgets[0].value,512);
  await assert.rejects(applyPrompt(f.app,prompt,{id:'expected',nodes:[{id:1}]}),/切换了当前画布/);
  assert.equal(f.source.widgets[0].value,512);
});

test('public frontend restoration state includes tabs and workspace spinner', () => {
  assert.equal(workspaceRestored({}),true);
  const app={extensionManager:{workflow:{tabsRestored:false},spinner:true}};
  assert.equal(workspaceRestored(app),false);
  app.extensionManager.workflow.tabsRestored=true;
  assert.equal(workspaceRestored(app),false);
  app.extensionManager.spinner=false;
  assert.equal(workspaceRestored(app),true);
});

test('node appearance changes only draw arguments and restores the original renderer', () => {
  const node = { color: '#335533', bgcolor: '#446644', pos: [17, 25], size: [320, 240], widgets: [{value: 'prompt'}] };
  const snapshot = JSON.stringify(node);
  const calls = [];
  const prototype = { drawNodeShape(...args) { calls.push(args); assert.equal(JSON.stringify(node), snapshot); return 42; } };
  const canvas = Object.create(prototype);
  canvas.setDirty = () => {};
  const original = canvas.drawNodeShape;
  assert.equal(setNodeAppearance(canvas, false), true);
  assert.equal(canvas.drawNodeShape, original);
  assert.equal(setNodeAppearance(canvas, true, {surface: '#313244'}), true);
  const wrapper = canvas.drawNodeShape;
  assert.equal(canvas.drawNodeShape(node, {}, node.size, node.color, node.bgcolor, true), 42);
  assert.equal(calls[0][0], node);
  assert.equal(calls[0][3], node.color);
  assert.equal(calls[0][4], '#313244');
  assert.equal(setNodeAppearance(canvas, true, {surface: '#3c3836'}), true);
  assert.equal(canvas.drawNodeShape, wrapper);
  canvas.drawNodeShape(node, {}, node.size, node.color, node.bgcolor, true);
  assert.equal(calls[1][4], '#3c3836');
  setNodeAppearance(canvas, false);
  assert.equal(canvas.drawNodeShape, original);
  assert.equal(Object.hasOwn(canvas, 'drawNodeShape'), false);
  assert.equal(JSON.stringify(node), snapshot);
});

test('appearance preserves extension render wrappers and rejects invalid colors', () => {
  let background;
  const canvas = { drawNodeShape(n, c, s, fg, bg) { background = bg; }, setDirty() {} };
  const original = canvas.drawNodeShape;
  assert.equal(setNodeAppearance(canvas, true, {surface: 'url(secret)'}), false);
  assert.equal(canvas.drawNodeShape, original);
  setNodeAppearance(canvas, true, {surface: '#313244'});
  const pocket = canvas.drawNodeShape;
  let extensionCalls = 0;
  canvas.drawNodeShape = function(...args) { extensionCalls++; return pocket.apply(this, args); };
  const extension = canvas.drawNodeShape;
  setNodeAppearance(canvas, false);
  assert.equal(canvas.drawNodeShape, extension);
  canvas.drawNodeShape({}, {}, [], '#fff', '#456');
  assert.equal(background, '#456');
  assert.equal(extensionCalls, 1);
  setNodeAppearance(canvas, true, {surface: '#3c3836'});
  canvas.drawNodeShape({}, {}, [], '#fff', '#456');
  assert.equal(background, '#3c3836');
  setNodeAppearance(canvas, false);
  assert.equal(canvas.drawNodeShape, extension);
  assert.equal(setNodeAppearance({}, true, {surface: '#313244'}), false);
});

function fixture() {
  const source = { id: 1, title: 'Source', outputs: [{ name: 'IMAGE', type: 'IMAGE' }], inputs: [],
    widgets: [{ name: 'width', value: 512 }], connect(slot, target, input) {
      if (this.outputs[slot].type !== target.inputs[input].type) return null;
      target.inputs[input].link = 7;
      return { id: 7 };
    } };
  const target = { id: 2, title: 'Target', outputs: [], inputs: [{ name: 'images', type: 'IMAGE', link: null }],
    disconnectInput(slot) { this.inputs[slot].link = null; } };
  let before = 0, after = 0;
  const graph = { _nodes: [source, target], getNodeById(id) { return this._nodes.find(n => String(n.id) === String(id)); },
    beforeChange() { before++; }, afterChange() { after++; } };
  const app = { rootGraph: graph, canvas: { graph, setDirty() {} },
    async graphToPrompt() { return { output: { '1': { inputs: { width: source.widgets[0].value } } } }; } };
  return { source, target, graph, app, transactions: () => [before, after] };
}

test('connect and disconnect edit the actual graph inside undoable transactions', () => {
  const f = fixture();
  let captures = 0;
  f.app.extensionManager = {workflow: {activeWorkflow: {changeTracker: {captureCanvasState() { captures++; }}}}};
  assert.equal(connect(f.app, '1', 0, '2', 0), true);
  assert.equal(f.target.inputs[0].link, 7);
  assert.equal(ports(f.app)[1].inputs[0].linked, true);
  disconnect(f.app, '2', 0);
  assert.equal(f.target.inputs[0].link, null);
  assert.deepEqual(f.transactions(), [2, 2]);
  assert.equal(captures, 4);
});

test('invalid ports and incompatible types fail without silently rewiring', () => {
  const f = fixture();
  assert.throws(() => connect(f.app, 'missing', 0, '2', 0));
  f.target.inputs[0].type = 'MODEL';
  assert.throws(() => connect(f.app, '1', 0, '2', 0), /类型不兼容/);
  assert.equal(f.target.inputs[0].link, null);
  assert.deepEqual(f.transactions(), [1, 1]);
});

test('latest mobile scalar edits update named widgets and invoke callbacks', async () => {
  const f = fixture();
  let updated;
  f.source.widgets[0].callback = value => { updated = value; };
  const unmatched = await applyPrompt(f.app, { '1': { inputs: { width: 1024 } } });
  assert.deepEqual(unmatched, []);
  assert.equal(updated, 1024);
  assert.equal(f.source.widgets[0].value, 1024);
});

test('unknown serializers and changed connections are reported for explicit rebuild', async () => {
  const f = fixture();
  const unmatched = await applyPrompt(f.app, { '1': { inputs: { custom: { x: 1 }, model: ['2', 0] } } });
  assert.deepEqual(unmatched, ['1.custom', '1.model']);
  assert.equal(f.source.widgets[0].value, 512);
});

test('execution node IDs resolve through nested subgraph instances', () => {
  const leaf = { id: 9, widgets: [] };
  const graph = { _nodes: [{ id: 2, subgraph: { _nodes: [{ id: 4, subgraph: { _nodes: [leaf] } }] } }] };
  assert.equal(executionNode(graph, '2:4:9'), leaf);
  assert.equal(executionNode(graph, '2:missing:9'), null);
});

const { mobileScene, setMobileWidget, moveMobileNode } = require('../ios/Pocket/CanvasBridge.js');
const { bookmarkLocations, focusBookmark } = require('../ios/Pocket/CanvasBridge.js');
test('bookmarks focus the real nested node and reject stale targets without changing graphs', () => {
  const f = fixture();
  const leaf = {id: 1, type: 'Text', title: 'Nested prompt', pos: [100, 200], size: [300, 200]};
  const child = {_nodes: [leaf]};
  f.source.subgraph = child;
  let selected;
  Object.assign(f.app.canvas, {
    ds: {scale: 1, offset: [0, 0]}, canvas: {getBoundingClientRect: () => ({width: 390, height: 600})},
    selectNode(node) { selected = node; }, setGraph(graph) { this.graph = graph; },
    openSubgraph(graph) { this.graph = graph; }
  });
  const originalPosition = [...leaf.pos];
  assert.equal(bookmarkLocations(f.app).bookmarkNodes.filter(n => n.nodeID === '1').length, 2);
  assert.throws(() => focusBookmark(f.app, ['missing'], '1', 'Text'), /子图已移除/);
  assert.equal(f.app.canvas.graph, f.graph);
  assert.equal(focusBookmark(f.app, ['1'], '1', 'Text'), true);
  assert.equal(selected, leaf);
  assert.equal(f.app.canvas.graph, child);
  assert.deepEqual(bookmarkLocations(f.app).graphPath, ['1']);
  assert.deepEqual(leaf.pos, originalPosition);
  assert.deepEqual(f.transactions(), [0, 0]);
  assert.throws(() => focusBookmark(f.app, ['1'], '1', 'OtherType'), /类型已改变/);
  assert.equal(f.app.canvas.graph, child);
  // A recursive custom graph must not make the navigation index loop forever.
  leaf.subgraph = f.graph;
  assert.equal(bookmarkLocations(f.app).bookmarkNodes.length, 3);
});
test('mobile scene preserves bypass states, groups and edges while hiding linked/internal widgets', () => {
  const f = fixture();
  Object.assign(f.source, {type:'Source',pos:[10,20],size:[280,300],mode:4});
  Object.assign(f.target, {type:'Target',pos:[30,400],size:[280,100],mode:0});
  f.graph._groups = [{title:'Generation',pos:[0,0],size:[600,700]}];
  f.graph.links = {7:{origin_id:1,target_id:2,type:'IMAGE'}};
  f.target.inputs[0].link=7;
  f.source.widgets.push({name:'timeline_data',value:'{}'}, {name:'linked',value:'do not edit'});
  f.source.inputs.push({widget:{name:'linked'},link:8});
  const scene=mobileScene(f.app);
  assert.equal(scene.nodes[0].mode,4); assert.equal(scene.nodes[0].group,'0');
  assert.deepEqual(scene.nodes[0].widgets.map(w=>w.name),['width']);
  assert.equal(scene.links[0].from,'1'); assert.equal(scene.links[0].to,'2');
});
test('mobile widget validation invokes custom callbacks and records asynchronous changes', async () => {
  const f=fixture(); let called=false;
  f.source.widgets[0].options={min:64,max:2048};
  f.source.widgets[0].callback=async ()=>{await Promise.resolve(); called=true;};
  await assert.rejects(setMobileWidget(f.app,'1','0',4096),/范围/);
  await setMobileWidget(f.app,'1','0',1024);
  assert.equal(called,true); assert.equal(f.source.widgets[0].value,1024);
  assert.deepEqual(f.transactions(),[1,1]);
  f.source.inputs.push({widget:{name:'width'},link:8});
  await assert.rejects(setMobileWidget(f.app,'1','0',512),/上游/);
});
test('node movement edits only geometry and participates in undo transactions', () => {
  const f=fixture(); f.source.pos=[1,2];
  moveMobileNode(f.app,'1',30,40);
  assert.deepEqual(f.source.pos,[30,40]); assert.equal(f.source.widgets[0].value,512);
  assert.throws(()=>moveMobileNode(f.app,'1',NaN,40));
  assert.deepEqual(f.transactions(),[1,1]);
});

const { executablePrompt, equivalentInput, focusNode, restoreExecutionModes } = require('../ios/Pocket/CanvasBridge.js');
test('hidden named scalar widgets survive API omission without reviving linked inputs', async () => {
  const f=fixture(); f.source.type='Source';
  f.source.widgets.push({name:'folded',value:0.8,type:'hidden',hidden:true}, {name:'linked',value:1,type:'hidden'});
  f.source.inputs.push({name:'linked',link:9});
  f.app.graphToPrompt=async()=>({output:{'1':{class_type:'Source',inputs:{width:512}}}});
  const result=await executablePrompt(f.app,{'1':{class_type:'Source',inputs:{folded:0.8,linked:['2',0]}}});
  assert.equal(result['1'].inputs.folded,0.8); assert.equal(result['1'].inputs.linked,undefined);
});
test('custom JSON ordering is equivalent but actual media and array order changes are not', () => {
  const expected={class_type:'LazyMergeWorkbench',inputs:{'图片数据':'[{"image":"a.png","mask":"b.png"}]'}};
  assert.equal(equivalentInput(expected,{inputs:{'图片数据':'[{"mask":"b.png","image":"a.png"}]'}},'图片数据'),true);
  assert.equal(equivalentInput(expected,{inputs:{'图片数据':'[{"mask":"c.png","image":"a.png"}]'}},'图片数据'),false);
});
test('restoring executed nodes follows the API prompt without activating unrelated bypassed stages', () => {
  const f=fixture(); Object.assign(f.source,{type:'Source',mode:4});Object.assign(f.target,{type:'Target',mode:4});
  restoreExecutionModes(f.app,{'1':{class_type:'Source',inputs:{}}});
  assert.equal(f.source.mode,0);assert.equal(f.target.mode,4);
});
test('custom serializer bypass remains bypassed and retains its execution flag', async () => {
  const f=fixture(); Object.assign(f.source,{type:'QwenImagePromptOptimizer',mode:4});
  const prompt={'1':{class_type:'QwenImagePromptOptimizer',inputs:{goohai_bypass:true}}};
  f.app.graphToPrompt=async()=>({output:{'1':{class_type:'QwenImagePromptOptimizer',inputs:f.source.mode===4?{goohai_bypass:true}:{}}}});
  const {output}=await f.app.graphToPrompt();
  restoreExecutionModes(f.app,prompt,output);
  assert.equal(f.source.mode,4);
  assert.deepEqual(await applyPrompt(f.app,prompt),[]);
});
test('wheel focus fits tall and wide nodes within both viewport axes without editing geometry', () => {
  const f=fixture(); const selected=[];
  Object.assign(f.app.canvas,{canvas:{getBoundingClientRect:()=>({width:360,height:500})},ds:{scale:1,offset:[0,0]},selectNode:n=>selected.push(n.id)});
  for(const size of [[280,1800],[1200,150]]){
    f.source.pos=[900,-400];f.source.size=size;
    focusNode(f.app,'1');const ds=f.app.canvas.ds;
    const left=(900+ds.offset[0])*ds.scale,top=(-432+ds.offset[1])*ds.scale;
    assert.ok(left>=19.99 && top>=19.99);
    assert.ok(left+size[0]*ds.scale<=340.01);
    assert.ok(top+(size[1]+32)*ds.scale<=480.01);
    assert.deepEqual(f.source.pos,[900,-400]); assert.deepEqual(f.source.size,size);
  }
  assert.deepEqual(selected,[1,1]);
});
test('canvas bridge waits for complete frontend setup instead of the first graph object', async () => {
  const vm=require('node:vm'),fs=require('node:fs');const messages=[];
  let resized=false;
  const app={canvas:{resize:()=>{resized=true;}},rootGraph:{},vueAppReady:true,loadGraphData:async()=>{},extensionManager:{focusMode:false,toggleFocusMode(){this.focusMode=true;}}};
  const context={window:{addEventListener(){},comfyAPI:{app:{app}},webkit:{messageHandlers:{pocketCanvas:{postMessage:m=>messages.push(m)}}}},document:{addEventListener(){},createElement:()=>({}),head:{append(){}}},setTimeout,clearTimeout,requestAnimationFrame:callback=>setTimeout(callback,0)};
  vm.runInNewContext(fs.readFileSync(require.resolve('../ios/Pocket/CanvasBridge.js'),'utf8'),context);
  await new Promise(r=>setTimeout(r,50));assert.equal(messages.some(m=>m.type==='ready'),false);
  app.positionConversion={};await new Promise(r=>setTimeout(r,200));
  assert.equal(messages.filter(m=>m.type==='ready').length,1);
  assert.equal(app.extensionManager.focusMode,true);assert.equal(resized,true);
});

test('startup follows actual setup completion when the frontend has no private conversion field', async () => {
  const vm=require('node:vm'),fs=require('node:fs'),messages=[];
  let finishRegistration,finishSetup;
  const app={canvas:{resize(){}},rootGraph:{},vueAppReady:true,loadGraphData:async()=>{},
    registerNodes:()=>new Promise(r=>{finishRegistration=r;}),
    async setup(){await this.registerNodes();await new Promise(r=>{finishSetup=r;});}};
  const context={window:{addEventListener(){},comfyAPI:{app:{app}},webkit:{messageHandlers:{pocketCanvas:{postMessage:m=>messages.push(m)}}}},document:{addEventListener(){},createElement:()=>({}),head:{append(){}}},setTimeout,clearTimeout,requestAnimationFrame:callback=>setTimeout(callback,0)};
  vm.runInNewContext(fs.readFileSync(require.resolve('../ios/Pocket/CanvasBridge.js'),'utf8'),context);
  const setup=app.setup();finishRegistration();await Promise.resolve();await Promise.resolve();
  await new Promise(r=>setTimeout(r,220));assert.equal(messages.some(m=>m.type==='ready'),false);
  finishSetup();await setup;await new Promise(r=>setTimeout(r,220));
  assert.equal(messages.filter(m=>m.type==='ready').length,1);
  assert.equal(app.positionConversion,undefined);
});

test('ready is delayed until saved tabs finish restoring after setup', async () => {
  const vm=require('node:vm'),fs=require('node:fs'),messages=[];
  const app={canvas:{resize(){}},rootGraph:{id:'qwen'},vueAppReady:true,positionConversion:{},loadGraphData:async()=>{},
    extensionManager:{workflow:{tabsRestored:false},spinner:true}};
  const context={window:{addEventListener(){},comfyAPI:{app:{app}},webkit:{messageHandlers:{pocketCanvas:{postMessage:m=>messages.push(m)}}}},document:{addEventListener(){},createElement:()=>({}),head:{append(){}}},setTimeout,clearTimeout,requestAnimationFrame:callback=>setTimeout(callback,0)};
  vm.runInNewContext(fs.readFileSync(require.resolve('../ios/Pocket/CanvasBridge.js'),'utf8'),context);
  await new Promise(r=>setTimeout(r,230));
  assert.equal(messages.some(m=>m.type==='ready'),false);
  assert.ok(messages.some(m=>m.type==='loading'&&m.message.includes('恢复工作流标签')));
  app.extensionManager.workflow.tabsRestored=true;app.extensionManager.spinner=false;
  await new Promise(r=>setTimeout(r,220));
  assert.equal(messages.filter(m=>m.type==='ready').length,1);
});

test('text input camera keeps the field readable inside keyboard and visual viewport bounds', () => {
  const {textInputCamera}=require('../ios/Pocket/CanvasBridge.js');
  for(const width of [120,400,1800]){
    const field={x:950,y:-600,width};const viewport={x:10,y:25,width:373,height:180};
    const camera=textInputCamera(field,viewport);
    const x=(field.x+camera.offset[0])*camera.scale,y=(field.y+camera.offset[1])*camera.scale;
    assert.ok(x>=25.99&&x+width*camera.scale<=367.01);
    assert.ok(y>=40.99&&y+camera.maxHeight*camera.scale<=189.01);
    assert.ok(camera.fontSize*camera.scale>=15.99);
  }
});
