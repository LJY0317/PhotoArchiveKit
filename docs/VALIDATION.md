# Validation Notes

검증 날짜: **2026-09-04**

이 문서는 vendor guarantee와 local observation을 구분한다. provider behavior는 바뀔 수 있으며 sample이 통과했다는 사실은 regression observation이지 permanent Apple/Google contract가 아니다.

## 5경로 local sample

Disposable set에는 새 iPhone Live Photo 3개와 ordinary video 1개가 있었다. 다음 경로로 확보했다.

1. iPhone Photos -> normal AirDrop
2. iPhone Photos -> AirDrop with **All Photos Data**
3. Google Photos iOS app -> AirDrop
4. Google Photos web -> browser download
5. macOS Image Capture -> filesystem folder

personal media, raw hash, raw Live Photo identifier는 repository에 commit하지 않는다.

### Full-byte comparison

| Image Capture와 비교 | Still resource | Live motion resource | Ordinary video |
|---|---:|---:|---:|
| AirDrop + All Photos Data | identical | identical | identical |
| Google Photos web | identical | identical | identical |
| Normal AirDrop | identical | 3개 모두 absent | identical |
| Google Photos iOS -> AirDrop | transformed file | pair not preserved | transformed representation |

Google web motion filename은 `.MP4`, Image Capture는 `.MOV`였지만 이 sample에서 byte는 identical했다. 이전의 반대 결과는 잘못된 comparison path를 선택한 것이 원인이었다.

### PhotoArchiveKit scan 결과

다섯 folder를 separate source root로 함께 scan했다.

```text
source roots                         5
media resources                     29
source-local media occurrences      20
provider-neutral logical assets      8
logical Live Photo assets            3
complete Live Photo occurrences      9
still-only Live Photo occurrences    3
exact resource duplicate groups      7
automatic event suggestions           1
warnings                              3
```

source-local occurrence 20개가 logical asset 8개로 합쳐지는 이유는 byte-identical ordinary media와 같은 protected linkage identifier를 가진 Live Photo copy를 unify하기 때문이다. root별 completeness는 계속 visible하므로 다른 위치의 complete copy가 normal-AirDrop occurrence의 incompleteness를 숨기지 않는다.

exact resource group 7개는 여러 경로에서 identical하게 보존된 still image 3개, motion resource 3개, ordinary video 1개다.

## Filename independence 관찰

- 올바른 still/motion pair는 두 filename을 모두 바꾼 뒤에도 Live Photo로 유지되었다.
- 한 Live Photo의 still과 다른 Live Photo의 motion resource는 basename을 같게 만들어도 Live Photo가 되지 않았다.
- test한 Google web HEIC + MP4 pair는 Apple Photos에 Live Photo로 import되었다.

따라서 PhotoArchiveKit은 embedded linkage evidence를 사용한다. basename은 disambiguation hint일 수 있지만 pairing authority가 아니다.

## `complete`의 의미

현재 scanner는 한 source root 안에서 recognized still 1개와 recognized motion resource 1개가 같은 protected Apple identifier를 공유할 때 occurrence를 complete라고 한다.

아직 다음을 증명하지는 않는다.

- complete media decodability
- correct timed `still-image-time` metadata
- expected audio
- edit, key-photo choice, adjustment state restoration
- future software version에서 identical behavior

## Provenance 결론

byte-identical file만으로 Image Capture와 Google Photos web 중 어디에서 왔는지 알 수 없다. provenance는 file content에서 추론하지 말고 source root, declared import method, relative path, scan session에서 기록해야 한다.

## 남은 high-value test

- 한 asset이 두 album에 들어간 small test-only Google Takeout export
- Edited Live Photo: key photo, crop, color adjustment, mute, Live on/off, effect
- Strict timed-metadata/decode validation
- Same-second capture, subsecond, burst, timezone change, metadata-free media
- Archive pair -> PhotoKit -> Apple Photos -> Google Photos iOS -> download round trip
- rclone upload/download 후 local full-byte comparison

이 test가 끝나기 전에도 architecture는 ordinary file, explicit resource relationship, source provenance, many-to-many collection, local equality group을 삭제나 rewrite 없이 안전하게 보존할 수 있다.
