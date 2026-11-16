(async () => {
  const savedWindows = __AGY_SAVED_WINDOWS__;
  const expected = Object.assign({}, ...savedWindows.map(saved => JSON.parse(saved.serializedDrafts)));
  const activeScope = savedWindows[0].scope;
  const normalize = value => Array.isArray(value) ? value.map(normalize) :
    value && typeof value === 'object' ? Object.fromEntries(Object.keys(value).sort().map(key => [key, normalize(value[key])])) : value;
  const equal = (a, b) => JSON.stringify(normalize(a)) === JSON.stringify(normalize(b));
  const hasText = node => !!node?.text || (node?.children || []).some(hasText);
  const root = document.getElementById('root');
  if (!root) throw new Error('GUI 尚未就绪。');
  const fiberKey = Object.keys(root).find(key => key.startsWith('__reactContainer$'));
  let first = root[fiberKey];
  first = first?.stateNode?.current || first;
  const queue = [first], seen = new Set();
  let store, storage, input;
  while (queue.length && seen.size < 40000) {
    const fiber = queue.pop();
    if (!fiber || seen.has(fiber)) continue;
    seen.add(fiber);
    const value = fiber.memoizedProps?.value;
    if (value?.store?.getState?.()?.inputDrafts) store = value.store;
    if (value?.inputBoxRef?.current?.setMediaAttachments && value.inputBoxRef.current.getMediaAttachments)
      input = value.inputBoxRef.current;
    for (const candidate of [value?.core?.storageService, value?.services?.core?.storageService])
      if (candidate?.flush && candidate?.get && candidate?.store) storage = candidate;
    queue.push(fiber.child, fiber.sibling);
  }
  if (!store || !storage) throw new Error('GUI 草稿恢复接口尚未就绪。');
  const scope = /^\/c\/([^/]+)/.exec(location.pathname)?.[1] || '__home__';
  if (scope !== activeScope) throw new Error('GUI 尚未到达原草稿位置。');
  const editors = Array.from(document.querySelectorAll('[contenteditable="true"][role="combobox"]'))
    .filter(element => element.__lexicalEditor);
  if (editors.length !== 1) throw new Error('输入编辑器尚未唯一就绪。');
  const editor = editors[0].__lexicalEditor;
  const before = editor.getEditorState().toJSON();
  if (expected[scope] && hasText(before.root) && !equal(before.root, expected[scope].editorStateJson.root))
    throw new Error('当前输入已发生变化，保留当前输入及保存副本。');
  const current = {...store.getState().inputDrafts.drafts};
  store.dispatch({type: 'inputDrafts/startPersistence', payload: {storageService: storage, analyticsService: null}});
  const decoded = {...store.getState().inputDrafts.drafts};
  for (const [id, draft] of Object.entries(current)) {
    if (!expected[id]) decoded[id] = draft;
  }
  store.dispatch({type: 'inputDrafts/restoreInputDrafts', payload: decoded});
  const draft = decoded[scope];
  for (const [id, item] of Object.entries(expected)) {
    if (!equal(decoded[id]?.editorStateJson, item.editorStateJson) ||
        decoded[id]?.media?.length !== item.media.length)
      throw new Error('已载入草稿与本次保存副本不一致，继续保留恢复记录。');
  }
  if (draft) {
    if (draft.media.length && !input) throw new Error('附件输入组件尚未就绪。');
    if (input && draft.media.length) {
      input.setMediaAttachments(draft.media);
      await new Promise(resolve => setTimeout(resolve, 200));
    }
    if (!equal(editor.getEditorState().toJSON().root, draft.editorStateJson.root)) {
      const serialized = draft.editorStateJson;
      const validate = node => {
        if (node.$slots || typeof editor._nodes?.get(node.type)?.klass?.importJSON !== 'function')
          throw new Error('当前草稿包含尚未支持的编辑节点，已保留磁盘副本。');
        for (const child of node.children || []) validate(child);
      };
      validate(serialized.root);
      const importNode = json => {
        const node = editor._nodes.get(json.type).klass.importJSON(json);
        if (json.children?.length) node.append(...json.children.map(importNode));
        return node;
      };
      editor.update(() => {
        const target = editor.getEditorState()._nodeMap.get('root');
        target.clear();
        target.updateFromJSON(serialized.root);
        target.append(...serialized.root.children.map(importNode));
      }, {discrete: true});
    }
    if (!equal(editor.getEditorState().toJSON().root, draft.editorStateJson.root))
      throw new Error('编辑器内容恢复核对失败，已保留恢复记录。');
    if (draft.media.length && !equal(input.getMediaAttachments(), draft.media))
      throw new Error('附件恢复核对失败，已保留恢复记录。');
  }
  await new Promise(resolve => setTimeout(resolve, 250));
  await storage.flush();
  const persisted = await window.nativeStorage.getItems();
  let confirmed;
  try { confirmed = JSON.parse(persisted['conversation-input-drafts'] || '{}'); }
  catch { throw new Error('恢复后的原生草稿存储格式不正确。'); }
  for (const [id, item] of Object.entries(expected))
    if (!equal(confirmed[id], item)) throw new Error('恢复后草稿或附件持久化核对失败。');
  return {restored: true, draftCount: Object.keys(decoded).length,
    checkedScopes: Object.keys(expected).length, editorVerified: true};
})()
