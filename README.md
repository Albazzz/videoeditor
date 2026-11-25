# video

A new Flutter project.

## Phụ đề theo từng video

- Phiên làm phụ đề tiếp tục khi chuyển hoặc đóng trang trong app. Mở lại đúng
  video sẽ nối vào phiên đang chạy; vào kho phụ đề để xem tiến độ và bấm **Dừng dịch**.
  Tiến độ được lưu định kỳ. Việc hệ điều hành đóng hoặc tạm ngưng cả app vẫn có
  thể ngắt xử lý; phụ đề đã lưu còn nguyên để làm tiếp.
- Chế độ **Tự nhận diện** gom nhiều câu có lời thoại, rồi giữ một ngôn ngữ cho cả
  video. Chưa đủ bằng chứng thì không tự đoán tiếng Nhật. Sửa ngôn ngữ trong
  **Chi tiết phụ đề** hoặc menu **Ngôn ngữ của video…**.
- Kho phân biệt URL trang và nguồn video, giữ cả tham số URL. Menu
  **Chọn video để gắn phụ đề…** dùng cho trang có nhiều video. Sub cũ chỉ gắn theo
  trang, hoặc nguồn đã đổi URL, cần chọn lại từ kho thay vì ghép tự động.
- **Yêu cầu dịch lại…** cho phép chọn một câu, một đoạn theo số câu hoặc toàn bộ
  sub, kèm yêu cầu riêng. Xem bản cũ/mới rồi **Áp dụng** hoặc **Hoàn tác** ngay
  trong cửa sổ này. Dịch lại dùng key OpenRouter/Vercel trong Cài đặt dịch, giữ
  lời gốc và thời gian, không nói giảm hay che lời tục. File nhập thiếu lời gốc
  vẫn sửa tay được nhưng không dùng bản dịch tiếng Việt thay cho lời gốc để dịch lại.

Pipeline có hàng đợi riêng cho lấy âm thanh, nhận dạng và dịch; giới hạn đồng
thời 2 lượt lấy âm thanh, 2 bộ nhận dạng và 3 yêu cầu dịch AI. Kết quả gắn với mã
video; việc đổi trang hoặc kết quả trả về muộn không được sửa sub của video khác.

Âm thanh được giữ riêng theo video cho đến khi người dùng xác nhận xóa, kể cả
khi làm xong, dừng dịch hoặc mở lại app. Bộ nhận dạng chỉ xóa bản làm việc tạm;
bản âm thanh giữ lại không nằm trong thư mục dọn cache. Vào **Kho phụ đề →
Âm thanh lưu riêng**, hoặc menu phụ đề của video, để xem dung lượng và chọn
**Xác nhận…**. Có thể tiếp tục giữ; nếu xác nhận xóa lúc đang xử lý, app sẽ dừng
phiên và chờ đóng các bộ ghi trước khi xóa. Phụ đề và video gốc không bị xóa.

Bấm **Làm tiếp** trong kho phụ đề, chi tiết hoặc kho âm thanh để dùng ngay
âm thanh đã lưu trong app, bỏ qua các đoạn đã nhận dạng. Nếu chỉ còn câu chưa
dịch, app dịch tiếp từ lời gốc mà không cần lấy lại âm thanh. App xử lý hết phần
âm thanh đang có trước; chỉ yêu cầu mở lại web khi còn thiếu đoạn cần nhận dạng.
Các mốc thời gian và file âm thanh gốc được giữ nguyên.

Tiến trình hiển thị riêng **Âm thanh đã lưu: …%**, **Đã nhận dạng: …%** và
**Đã dịch: … / … câu** trong thanh video, kho phụ đề và kho âm thanh. Phần trăm
âm thanh tính từ các WAV đã ghi xong, gộp các lượt tải trùng và giữ nguyên khoảng
trống; file đang ghi dở không được tính. Có một file âm thanh chưa có nghĩa là
đã tải hết. Nếu nguồn bị chặn trước khi đủ âm thanh, app báo mốc thiếu và xử lý
được phần đã lưu; khi chưa rõ tổng thời lượng, chỉ hiện thời lượng đang có.

Trên Android, kho âm thanh ở `noBackupFilesDir`; trên iOS, ở Application Support
với quyền thư mục chỉ dành cho chủ sở hữu, Data Protection và loại khỏi backup.
Kho này không được đưa vào Documents, Tệp, MediaStore hoặc chức năng chia sẻ;
video trong kho ẩn cũng không xuất hiện ở danh sách âm thanh chung.
Xem [lưu trữ riêng trên Android](https://developer.android.com/training/data-storage/app-specific)
và [lưu trữ hỗ trợ ứng dụng trên iOS](https://developer.apple.com/documentation/foundation/using-the-file-system-effectively).

Kiểm tra: `flutter test`, `dart analyze lib test`,
`node --test test/page_script_test.mjs`.

## Ảnh đại diện, bản dịch trang và thử lại

- Khi lưu trang hoặc nhập phụ đề, có thể xem/chọn ảnh đại diện trước khi xác nhận.
  Menu ba chấm trên trang web có **Chụp ảnh đại diện…** để kéo khoanh vùng và
  dùng vùng đã chọn, kể cả trước khi lưu trang. Ảnh đã chọn được giữ khi lưu sau đó.
  Trong trình duyệt có thể chụp lại trang; trên điện thoại có thể chụp bằng camera.
  Ảnh chụp được giữ trong dữ liệu riêng của app, không thêm vào thư viện ảnh.
  Menu trang lưu và phụ đề cho phép đổi ảnh; ảnh phụ đề được giữ riêng theo video.
- Nhãn **Có bản dịch** và **Có âm thanh** cho biết nội dung hiện có trong kho.
  Tiến độ nhận dạng vẫn hiển thị riêng để phân biệt phần đã nghe với phần đã dịch.
- Dịch nội dung trang chỉ giữ tạm trong tab đang mở. App không lưu bản dịch trang
  lâu dài; dữ liệu `page_tr` của bản cũ được dọn khi khởi động, giữ nguyên phụ đề video.
- Khi gặp lỗi, dùng **Thử lại** ở thanh video, tiến trình hoặc chi tiết phụ đề.
  App giữ các đoạn đã nhận dạng và các câu đã dịch, rồi làm tiếp phần thiếu.
  Nhập phụ đề bị lỗi một phần cũng cho thử lại hoặc nhập phần đã dịch.

## Tiến trình nền và hoàn tất

- Thanh tiến trình chỉ ghi **Sub: số video đã xong / tổng video hoàn thành**,
  không gửi tên phim, URL hay key sang thông báo hệ thống. Số đếm chỉ tăng sau
  khi lưu xong kết quả; video lỗi hoặc bị huỷ không được tính là hoàn thành.
- iOS 26 trở lên dùng Continuous Background Task với Live Activity của hệ thống.
  Cần build bằng Xcode 26 trở lên. iOS cũ hơn vẫn có thanh tiến trình trong app.
  Huỷ từ Live Activity dừng các phiên và giữ dữ liệu đã làm.
- Android dùng foreground service khi xử lý, với thông báo riêng không có tên
  phim. Chạm thông báo mở kho phụ đề; thông báo kết thúc không còn giữ dịch vụ.
- Khi đã nghe, dịch và lưu xong, phiên tự kết thúc, bỏ nút **Dừng dịch** và đưa
  phụ đề web về **Chưa phân loại**. Âm thanh vẫn được giữ cho đến khi xác nhận xoá.
  Bộ lọc **Chưa xoá âm thanh** giúp tìm những video cần kiểm tra/dọn âm thanh.
- **Cài đặt → Cách dịch → Vercel AI Gateway → Số dư Vercel** đọc số USD còn lại
  và tổng đã dùng bằng key đã nhập. Đây là số dư chung của nhóm Vercel gắn với key;
  Token Pass hiển thị riêng nếu có. Có nút cập nhật, báo lỗi và thời điểm cập nhật.

## Getting Started

This project is a starting point for a Flutter application.

A few resources to get you started if this is your first Flutter project:

- [Learn Flutter](https://docs.flutter.dev/get-started/learn-flutter)
- [Write your first Flutter app](https://docs.flutter.dev/get-started/codelab)
- [Flutter learning resources](https://docs.flutter.dev/reference/learning-resources)

For help getting started with Flutter development, view the
[online documentation](https://docs.flutter.dev/), which offers tutorials,
samples, guidance on mobile development, and a full API reference.
