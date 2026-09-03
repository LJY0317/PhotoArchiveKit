# Ingest 가이드

가장 안전한 ingest 경로는 selection, rename, organization, deletion을 시작하기 전에 모든 original resource를 보존하는 경로다.

## 권장 기본값: Image Capture

현재 Mac-first workflow:

```text
iPhone
  -> USB connection
  -> macOS Image Capture
  -> configured Photo Inbox
  -> PhotoArchiveKit read-only scan
```

장점:

- ordinary Finder folder에 직접 쓴다.
- 먼저 Apple Photos library로 import할 필요가 없다.
- validated fixture에서 complete HEIC + MOV Live Photo resource를 보존했다.
- transfer할 때마다 AirDrop export option을 기억할 필요가 없다.
- explicit, occasional archive session에 잘 맞는다.

초기 사용 중에는 import 후 iPhone에서 media를 삭제하는 option을 enable하지 않는다. 먼저 import하고, scan하고, verify하고, 다른 copy를 만든 뒤 별도의 deletion decision을 한다.

## AirDrop

### All Photos Data enabled

validated fixture에서 iPhone Photos share option의 **All Photos Data**를 enable하면 Image Capture와 byte-identical한 resource가 생성되었다.

다음 share에서도 setting이 유지된다는 보장이 없으므로 secondary method로 취급한다. future UI/documentation은 항상 이 option 확인을 안내해야 한다.

### Ordinary Photos AirDrop

같은 fixture에서:

- HEIC still 3개는 Image Capture와 byte-identical이었다.
- Live Photo motion resource 3개는 모두 missing이었다.
- independent normal video는 보존되었다.

따라서 ordinary AirDrop은 default archival ingest path로 안전하지 않다. 다른 scanned root에 complete copy가 있어도 PhotoArchiveKit은 still-only Live Photo occurrence를 root별로 report한다.

## Google Photos

### Web download

test한 Google Photos web download에는 다음이 있었다.

```text
IMG_TEST.HEIC
IMG_TEST.MP4
```

Image Capture reference에는:

```text
IMG_TEST.HEIC
IMG_TEST.MOV
```

Live Photo 3개와 normal video 모두 local byte comparison에서 Image Capture resource와 동일했다. `.MP4` extension 차이는 byte 차이를 의미하지 않았다. embedded Live Photo linkage metadata도 유효했다.

이는 해당 item에 대해 Google Photos가 emergency recovery source가 될 수 있다는 유의미한 evidence다. universal contract는 아니다. Google Photos, iOS, file format, account storage setting이 크게 바뀌면 다시 test해야 한다.

### Google Photos iOS app -> AirDrop

test한 share path는 archival HEIC + paired-video resource 대신 UUID-named JPG와 MP4를 만들었다. exported media로는 쓸 수 있지만 known original을 대체해서는 안 된다.

explicit equivalence relation이 나중에 확립되기 전까지 PhotoArchiveKit은 이를 standalone 또는 derived candidate로 classify해야 한다.

### Google Takeout

현재 fixture로는 Takeout을 검증하지 않았다. 첫 download에서는 directory structure와 JSON sidecar를 그대로 보존한다.

권장 첫 Takeout experiment:

1. disposable asset A, B, C를 만든다.
2. A는 `Trip` album에만 넣는다.
3. B는 `Family` album에만 넣는다.
4. C는 두 album 모두에 넣는다.
5. 가능하면 test data만 export한다.
6. untouched archive를 baseline으로 보존한다.
7. working copy를 PhotoArchiveKit으로 scan한다.
8. resource count, Live Photo completeness, exact-copy result, JSON linkage, album representation을 기록한다.
9. Apple Photos re-import는 test library에서만 시도한다.

guess한 sidecar naming rule을 기반으로 parser를 만들지 않는다. 먼저 real, versioned fixture를 확보한다.

## Apple Photos export

Apple Photos는 특히 future PhotoKit adapter를 위해 유용한 Live Photo-aware source다. ordinary Finder archiving에서 unmodified original export는 Image Capture에는 없는 library import/export step을 추가한다.

Apple Photos를 사용할 상황:

- asset이 Photos library에만 존재
- edited/current와 original variant 비교가 필요
- PhotoKit-based restore test 수행
- album을 observe/project해야 함

archive 목적이 original resource라면 **Export Unmodified Original**을 사용한다. optional sidecar는 별도로 보존하고 minimum Live Photo pair의 일부라고 가정하지 않는다.

## Source provenance

두 file이 byte-identical하면 byte만으로 한쪽이 Image Capture, 다른 쪽이 Google Photos web download였는지 알 수 없다.

따라서 provenance는 ingest context에서 기록해야 한다.

```text
root type
root label
scan session
relative source path
user-declared import method
```

metadata나 filename convention으로 나중에 추론하지 않는다.

## 안전한 첫 archive sequence

1. source device에서 삭제하지 않고 새 Inbox로 import
2. Inbox와 comparison root에 `photoarchive scan` 실행
3. incomplete Live Photo warning 해결
4. exact duplicate group을 deletion instruction이 아니라 relationship으로 review
5. testing 중 original filename/file 유지
6. second copy 생성 및 verify
7. 반복 session이 성공한 뒤에만 작은 copied subset에 future rename/copy planning 적용
8. provider cleanup과 permanent deletion은 별도 later operation으로 유지

## Future ingest assistant 권장 문구

- **Preferred:** configured Photo Inbox로 Image Capture를 사용해 import한다.
- **Alternative:** Apple Photos에서 AirDrop할 때마다 All Photos Data를 enable한다.
- **Warning:** ordinary AirDrop은 Live Photo motion resource를 누락할 수 있다.
- **Warning:** Google Photos iOS app share는 transformed standalone file을 만들 수 있다.
- **Note:** test한 Google Photos web download는 byte-identical했지만 Takeout과 future version은 추가 validation이 필요하다.
