(async () => {
  const key = 'conversation-input-drafts';
  const root = document.getElementById('root');
  if (!root || !window.nativeStorage?.updateItems || !window.nativeStorage?.getItems)
    throw new Error('当前窗口没有可验证的原生草稿存储接口。');
  const fiberKey = Object.keys(root).find(k => k.startsWith('__reactContainer$'));
  let first = root[fiberKey];
  first = first?.stateNode?.current || first;
  const queue = [first], seen = new Set();
  let store, storage;
  while (queue.length && seen.size < 40000) {
    const fiber = queue.pop();
    if (!fiber || seen.has(fiber)) continue;
    seen.add(fiber);
    const value = fiber.memoizedProps?.value;
    if (!store && value?.store?.getState?.()?.inputDrafts) store = value.store;
    for (const candidate of [value?.core?.storageService, value?.services?.core?.storageService])
      if (candidate?.store && candidate?.flush && candidate?.get) storage = candidate;
    queue.push(fiber.child, fiber.sibling);
  }
  if (!store) throw new Error('未找到当前应用的输入草稿状态，保留软件进程。');
  await new Promise(resolve => setTimeout(resolve, 400));
  const scope = /^\/c\/([^/]+)/.exec(location.pathname)?.[1] || '__home__';
  const editors = Array.from(document.querySelectorAll('[contenteditable="true"][role="combobox"]'))
    .filter(element => element.__lexicalEditor);
  if (editors.length !== 1) throw new Error('无法唯一确认当前窗口的输入编辑器，保留软件进程。');
  const draftsBefore = {...store.getState().inputDrafts.drafts};
  const activeDocument = editors[0]?.__lexicalEditor.getEditorState().toJSON();
  const originalItems = await window.nativeStorage.getItems();
  const originalSerialized = originalItems[key];
  if (storage) {
    store.dispatch({type: 'inputDrafts/startPersistence', payload: {storageService: storage, analyticsService: null}});
    store.dispatch({type: 'inputDrafts/restoreInputDrafts', payload: {
      ...store.getState().inputDrafts.drafts, ...draftsBefore
    }});
  }
  if (editors.length === 1) {
    const editorStateJson = activeDocument;
    if (editorStateJson.root?.children)
      editorStateJson.root.children = editorStateJson.root.children.map(paragraph => ({
        ...paragraph,
        ...(paragraph.children ? {children: paragraph.children.filter(node => node.type !== 'ghost-text')} : {})
      }));
    const hasText = node => !!node?.text || (node?.children || []).some(hasText);
    if (draftsBefore[scope] || hasText(editorStateJson.root)) {
      const media = draftsBefore[scope]?.media || [];
      store.dispatch({type: 'inputDrafts/setInputDraft', payload: {
        scope, draft: {editorStateJson, media}
      }});
    }
  }
  await new Promise(resolve => setTimeout(resolve, 250));
  if (storage) await storage.flush();
  const drafts = store.getState().inputDrafts.drafts;
  let serialized = storage?.get(key) || originalSerialized;
  let nativeDrafts;
  try { nativeDrafts = JSON.parse(serialized || '{}'); } catch { nativeDrafts = {}; }
  const sameDocument = (a, b) => JSON.stringify(a?.editorStateJson) === JSON.stringify(b?.editorStateJson);
  const complete = Object.keys(drafts).every(id =>
    sameDocument(nativeDrafts[id], drafts[id]) &&
    Array.isArray(nativeDrafts[id]?.media) &&
    nativeDrafts[id].media.length === (drafts[id].media || []).length);
  if (!complete) {
    if (Object.values(drafts).some(draft => (draft.media || []).length))
      throw new Error('应用未确认全部附件和草稿完成持久化，保留软件进程。');
    nativeDrafts = {...nativeDrafts, ...Object.fromEntries(Object.entries(drafts).map(([id, draft]) =>
      [id, {editorStateJson: draft.editorStateJson, media: []}]))};
    serialized = JSON.stringify(nativeDrafts);
    if (storage) {
      storage.store(key, serialized);
      await storage.flush();
    }
  }
  if (typeof serialized !== 'string') serialized = JSON.stringify(nativeDrafts || {});
  // The native handler awaits fs.writeFile. Compare the returned on-disk value.
  await window.nativeStorage.updateItems({[key]: serialized});
  const confirmed = await window.nativeStorage.getItems();
  if (confirmed[key] !== serialized) throw new Error('原生存储写入核对失败，保留软件进程。');
  return {
    verified: true, scope, route: location.pathname + location.search,
    serializedDrafts: serialized, draftCount: Object.keys(nativeDrafts).length,
    mediaCount: Object.values(nativeDrafts).reduce((n, draft) => n + (draft.media || []).length, 0),
    editorCount: editors.length
  };
})()
