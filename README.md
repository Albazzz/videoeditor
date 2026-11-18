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

Trên Android, kho âm thanh ở `noBackupFilesDir`; trên iOS, ở Application Support
với quyền thư mục chỉ dành cho chủ sở hữu, Data Protection và loại khỏi backup.
Kho này không được đưa vào Documents, Tệp, MediaStore hoặc chức năng chia sẻ;
video trong kho ẩn cũng không xuất hiện ở danh sách âm thanh chung.
Xem [lưu trữ riêng trên Android](https://developer.android.com/training/data-storage/app-specific)
và [lưu trữ hỗ trợ ứng dụng trên iOS](https://developer.apple.com/documentation/foundation/using-the-file-system-effectively).

Kiểm tra: `flutter test`, `dart analyze lib test`,
`node --test test/page_script_test.mjs`.

## Getting Started

This project is a starting point for a Flutter application.

A few resources to get you started if this is your first Flutter project:

- [Learn Flutter](https://docs.flutter.dev/get-started/learn-flutter)
- [Write your first Flutter app](https://docs.flutter.dev/get-started/codelab)
- [Flutter learning resources](https://docs.flutter.dev/reference/learning-resources)

For help getting started with Flutter development, view the
[online documentation](https://docs.flutter.dev/), which offers tutorials,
samples, guidance on mobile development, and a full API reference.
