# 08 — Collections in the Records UI

Status: done (user-verified 2026-10-26)
Type: feature

## Summary

The phone app groups Records into user-named Collections (user screenshot 2026-10-26). Show them in the macOS client: fetch `storage/collection/v1/list`, map Cards to Collections via `card_collection_cross_ref`, and filter the Records sidebar.

## Delivered

- [x] Wire models: `CardCollectionCrossRef` + `CardPayload.cardCollectionCrossRefs` → `Record.collectionIds`; `CollectionSummary` gains `clientCreateTime/UpdateTime` for ordering
- [x] `AppModel.loadCollections()` (secondary like preferences — only a dead session surfaces), plus `filteredRecords(collectionID:)`, `recordCount(in:)` (cross-ref count of loaded Records beats the sometimes-stale server `count`), `collectionNames(for:)`
- [x] Sidebar: COLLECTIONS chip bar ("All Records" + one chip per Collection with count, gradient fill when selected), empty-Collection state, selection cleared when it falls out of the filter; RecordDetail header shows the Record's Collection names
- [x] Tests: collection envelope decoding (captured shape, lenient fields), `ESClient.fetchCollections` request shape (path / POST / `{"sinceTime":0}` / legacy headers), AppModel load + local-count-beats-server-count + filter helpers; fixture cross-ref assertions — 62/62 green

## Comments

- 2026-10-26 — captured response shape (live capture, notes/03): `data:[{collectionId,collectionName,count,clientUpdateTime,clientCreateTime}]`; `{"sinceTime":0}` lists every Collection. `count` was stale (0) in the capture while the Cards carried cross-refs, hence the local-first count.
