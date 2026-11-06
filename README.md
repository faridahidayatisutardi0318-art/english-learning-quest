# English Learning Quest — Multiplayer Edition

## Isi
- `index.html` — portal tiga mata kuliah.
- `games/grammar.html` — Grammar Newsroom dengan Supabase Live Classroom / Classic Quiz.
- `games/journalism.html` — Baby Reporters dengan Supabase Live Classroom / Classic Quiz; Snake & Ladder lokal asli tetap tersedia.
- `games/tourism.html` — Tourism Quest dengan Supabase Live Classroom.
- `supabase/setup.sql` — schema dan RPC database.

## Supabase setup
1. Buat project Supabase.
2. Aktifkan Authentication > Providers > Anonymous Sign-Ins.
3. Jalankan seluruh `supabase/setup.sql` di SQL Editor.
4. Ambil Project URL dan anon/public key. Jangan gunakan service_role key di browser.
5. Buka masing-masing game, klik **Multiplayer / Live PIN**, masukkan URL dan anon key, lalu Connect. Konfigurasi disimpan lokal pada browser.

## GitHub Pages
1. Buat repository GitHub.
2. Upload seluruh isi paket ke root repository.
3. Settings > Pages > Deploy from a branch > `main` > `/ (root)`.
4. Buka URL Pages; portal `index.html` menampilkan tiga mata kuliah.

## Host session
- Pilih game mata kuliah yang diinginkan.
- Hubungkan Supabase.
- Isi class name dan class code, pilih learning set, individual/group, jumlah soal, dan timer.
- Create session, bagikan PIN kepada mahasiswa.
- Mahasiswa membuka halaman game yang sama, menghubungkan Supabase, lalu memasukkan PIN, nickname, dan nama tim jika mode group.
- Host menekan Start, Next question, atau Finish.
- Leaderboard diperbarui melalui Supabase Realtime.

## Status implementasi
- Grammar: multiplayer Classic Quiz dengan Supabase PIN, individual/group scoring, live/final leaderboard.
- Journalism: multiplayer Classic Quiz dengan Supabase PIN, individual/group scoring, live/final leaderboard. Snake & Ladder original tetap dapat dimainkan lokal; sinkronisasi posisi papan antarperangkat belum diimplementasikan.
- Tourism: fitur Live Classroom yang telah ada tetap dipertahankan.
- Tidak ada roster mahasiswa atau NIM wajib. Nickname + Game PIN digunakan untuk masuk.
- Koneksi peserta memakai Supabase anonymous auth; ini identitas sesi, bukan verifikasi identitas akademik.

## Keamanan dan pengujian
- Jangan memasukkan service_role key ke frontend.
- RLS dan RPC database memproses jawaban/skor; tetap lakukan uji di project terpisah sebelum penggunaan kelas resmi.
- Leaderboard menampilkan nickname, bukan NIM.
- Lakukan uji dua browser/perangkat terlebih dahulu. Untuk kelas Tourism 47 peserta, lakukan uji beban bertahap dan pantau quota Supabase.
