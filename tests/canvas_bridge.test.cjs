const test = require('node:test');
const assert = require('node:assert/strict');
const { executionNode, applyPrompt, ports, connect, disconnect } = require('../ios/Pocket/CanvasBridge.js');

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
  const context={window:{comfyAPI:{app:{app}},webkit:{messageHandlers:{pocketCanvas:{postMessage:m=>messages.push(m)}}}},document:{createElement:()=>({}),head:{append(){}}},setTimeout,requestAnimationFrame:callback=>setTimeout(callback,0)};
  vm.runInNewContext(fs.readFileSync(require.resolve('../ios/Pocket/CanvasBridge.js'),'utf8'),context);
  await new Promise(r=>setTimeout(r,50));assert.equal(messages.some(m=>m.type==='ready'),false);
  app.positionConversion={};await new Promise(r=>setTimeout(r,200));
  assert.equal(messages.filter(m=>m.type==='ready').length,1);
  assert.equal(app.extensionManager.focusMode,true);assert.equal(resized,true);
});
