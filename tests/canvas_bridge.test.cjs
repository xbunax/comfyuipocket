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
