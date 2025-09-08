#!/usr/bin/perl

use strict;
use warnings;
use HTTP::Daemon;               # 간단한 HTTP 서버를 만드는 모듈
use HTTP::Status;               # 상태코드 상수(200, 404, 405 등)
use File::Spec;                 # OS 독립적인 경로 결합/정규화 유틸
use File::MimeInfo::Simple;     # (설치돼 있지만, 아래 코드에선 실제로 안 씀)
use File::Basename;             # (사용되지 않음)
use CGI qw(escapeHTML);         # HTML 이스케이프(디렉토리 목록 출력 시 사용)

my $webroot = "./files";        # 정적 루트 디렉터리. 여기 안의 파일/폴더만 서비스 의도

my $d = HTTP::Daemon->new(
    LocalAddr => '0.0.0.0',     # 모든 인터페이스 바인딩
    LocalPort => 8080,          # 8080 포트 오픈
    Reuse     => 1              # 포트 재사용
) || die "Failed to start server: $!";   # 서버 소켓 생성 실패 시 종료

print "Server running at: ", $d->url, "\n";  # 예: http://0.0.0.0:8080/

while (my $c = $d->accept) {                # 클라이언트 연결 수락(블로킹)
    while (my $r = $c->get_request) {       # 요청 단위 루프
        if ($r->method eq 'GET') {          # 오직 GET만 처리(HEAD/POST 등은 불가)
            my $path = CGI::unescape($r->uri->path);
            # URL 퍼센트 인코딩 1회 디코딩. 예: %2F -> "/"
            # [주의] 이중 인코딩(%252e%252e) 등은 여기서 한 번만 풀림.

            $path =~ s|^/||;               # 선행 슬래시 제거 -> 상대경로화
            $path ||= 'index.html';        # 빈 경로면 index.html로 대체

            my $fullpath = File::Spec->catfile($webroot, $path);
            # webroot와 요청 경로 결합. 예: "./files/aaa/bbb.txt"

            if ($fullpath =~ /\.\.|[,\`\)\(;&]|\|.*\|/) {
                # 경로 필터:
                #  - ".." 포함 차단 (디렉터리 트래버설 기본 패턴)
                #  - 쉘 메타문자 일부(, ` ) ( ; & |...|) 차단 (명령 인젝션류 예방 의도)
                $c->send_error(RC_BAD_REQUEST, "Invalid path");
                next;
            }

            if (-d $fullpath) {             # 요청 대상이 '디렉터리'인 경우
                # 디렉터리 목록을 생성해서 반환
                opendir(my $dh, $fullpath) or do {
                    $c->send_error(RC_FORBIDDEN, "Cannot open directory.");
                    next;
                };

                my @files = readdir($dh);   # 현재 디렉터리 항목들(., .. 포함)
                closedir($dh);

                my $html = "<html><body><h1>Index of /$path</h1><ul>";
                foreach my $f (@files) {
                    next if $f =~ /^\./;    # 점으로 시작(dotfiles) 숨김(., .., .git 등)
                    my $link = "$path/$f";  # 하위 경로 링크 구성
                    $link =~ s|//|/|g;      # 중복 슬래시 정리
                    # 표시는 escapeHTML로 이스케이프(텍스트), href는 그대로(속성 이스케이프 없음)
                    $html .= qq{<li><a href="/$link">} . escapeHTML($f) . "</a></li>";
                }
                $html .= "</ul></body></html>";

                my $resp = HTTP::Response->new(RC_OK);
                $resp->header("Content-Type" => "text/html");
                $resp->content($html);
                $c->send_response($resp);

            } else {
                # '파일'인 경우: 내용을 통째로 읽어 그대로 반환
                open(my $fh, $fullpath) or do {
                    $c->send_error(RC_INTERNAL_SERVER_ERROR, "Could not open file.");
                    next;
                };
                binmode $fh;                 # 바이너리 모드
                my $content = do { local $/; <$fh> };  # 전체 파일 읽기
                close $fh;

                my $mime = 'text/html';
                
                my $resp = HTTP::Response->new(RC_OK);
                $resp->header("Content-Type" => $mime);
                $resp->content($content);
                $c->send_response($resp);
            }
        } else {
            # GET 이외의 메서드는 405(Method Not Allowed)
            $c->send_error(RC_METHOD_NOT_ALLOWED);
        }
    }
    $c->close;
    undef($c);
}

