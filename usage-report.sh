#!/usr/bin/env bash
# Claude Code 토큰 사용량 리포트 (READ-ONLY, 파이프라인 비침습)
# Claude Code가 ~/.claude/projects/<프로젝트>/*.jsonl 에 남기는 세션 기록을 읽어
# "프로젝트 진행 동안 쓴 토큰"을 전체적으로 집계한다.
#
# 사용법:
#   bash usage-report.sh                  # [개요] 전 프로젝트 누적(전체 기간), 소비순 정렬
#   bash usage-report.sh 30               # [개요] 최근 30일만
#   bash usage-report.sh olympus          # [상세] 해당 프로젝트 누적(모델·일자별)
#   bash usage-report.sh olympus 30       # [상세] 최근 30일
#     ※ 올림푸스 과거 기록은 리네임 전이라 'pipeline' 폴더에 있음 → `bash usage-report.sh pipeline`
#
# 주의: 표의 '$'는 실제 청구가 아니라 종량제 API 단가 환산가치(Pro/Max는 정액).
set -euo pipefail

BASE="$HOME/.claude/projects"
PROJ_KEY="$(printf "%s" "${PROJECTS_DIR:-$HOME/projects}" | sed "s#/#-#g")"   # Claude Code 세션 디렉토리 이름 규칙(경로의 / → -)
HOME_KEY="$(printf "%s" "$HOME" | sed "s#/#-#g")"

# --html [일수] : 브라우저용 대시보드 생성 후 열기
if [ "${1:-}" = "--html" ]; then
  shift; DAYS="${1:-0}"; CUTOFF="0000-00-00"; PERIOD="전체 기간"
  if [ "$DAYS" -gt 0 ] 2>/dev/null; then
    CUTOFF="$(date -v-"${DAYS}"d +%Y-%m-%d 2>/dev/null || date -d "-${DAYS} days" +%Y-%m-%d)"; PERIOD="최근 ${DAYS}일"
  fi
  GEN="$(date '+%Y-%m-%d %H:%M')"
  OUT="${USAGE_HTML_OUT:-$HOME/projects/olympus/usage.html}"
  emit_html() {
    find "$BASE" -maxdepth 1 -mindepth 1 -type d | while IFS= read -r d; do
      proj="$(basename "$d")"
      case "$proj" in
        "$HOME_KEY") proj="홈-CLI세션";;
        "$PROJ_KEY") proj="프로젝트-루트";;
        -) proj="기타";;
        *) proj="${proj#"$PROJ_KEY"-}"; proj="${proj#"$HOME_KEY"-}";;
      esac
      cat "$d"/*.jsonl 2>/dev/null | jq -rc --arg cut "$CUTOFF" --arg p "$proj" '
        select(.type=="assistant" and (.message.usage != null))
        | (.timestamp[0:10]) as $day | select($day >= $cut)
        | [ $p, $day, (.message.model//"?"),
            (.message.usage.input_tokens//0),(.message.usage.output_tokens//0),
            (.message.usage.cache_read_input_tokens//0),(.message.usage.cache_creation_input_tokens//0)] | @tsv' || true
    done
  }
  emit_html | awk -F'\t' -v gen="$GEN" -v period="$PERIOD" '
    function price(m){ if(m~/opus/)return "5 25"; else if(m~/haiku/)return "1 5"; else if(m~/sonnet/)return "3 15"; else if(m~/glm/)return "0.6 2.2"; else return "3 15" }
    function hum(n){ if(n>=1e9)return sprintf("%.2fB",n/1e9); if(n>=1e6)return sprintf("%.1fM",n/1e6); if(n>=1e3)return sprintf("%.0fk",n/1e3); return sprintf("%d",n) }
    function usd(c){ if(c>=1000)return sprintf("$%.0f",c); return sprintf("$%.2f",c) }
    function esc(s){ gsub(/&/,"\\&amp;",s); gsub(/</,"\\&lt;",s); return s }
    {
      proj=$1;day=$2;model=$3;ini=$4;out=$5;cr=$6;cc=$7;
      split(price(model),p," "); cost=(ini*p[1]+cr*p[1]*0.1+cc*p[1]*1.25+out*p[2])/1e6;
      Pcost[proj]+=cost;Pout[proj]+=out;Ptok[proj]+=ini+out+cr+cc;Pn[proj]++;
      if(Pmin[proj]==""||day<Pmin[proj])Pmin[proj]=day; if(day>Pmax[proj])Pmax[proj]=day;
      Tcost+=cost;Ttok+=ini+out+cr+cc;Tn++;
      if(min==""||day<min)min=day; if(day>max)max=day;
    }
    END{
      k=0; for(pr in Pcost){K[++k]=pr; if(Pcost[pr]>mx)mx=Pcost[pr]}
      for(i=1;i<k;i++)for(j=i+1;j<=k;j++)if(Pcost[K[j]]>Pcost[K[i]]){t=K[i];K[i]=K[j];K[j]=t}
      print "<!doctype html><html lang=\"ko\"><head><meta charset=\"utf-8\">";
      print "<meta name=\"viewport\" content=\"width=device-width,initial-scale=1\"><title>토큰 사용량</title></head><body>";
      print "<style>";
      print ":root{--bg:#0f1417;--panel:#161c21;--line:#242c33;--tx:#c9d1d6;--mut:#8a969e;--acc:#e8a13a;--accd:#7a5a24}";
      print "*{box-sizing:border-box}body{margin:0;background:var(--bg);color:var(--tx);font-family:system-ui,-apple-system,sans-serif;line-height:1.5}";
      print ".wrap{max-width:900px;margin:0 auto;padding:44px 22px 64px}";
      print ".eyebrow{font:600 11px/1 ui-monospace,Menlo,monospace;letter-spacing:.18em;color:var(--acc);text-transform:uppercase}";
      print "h1{font-size:30px;font-weight:700;letter-spacing:-.02em;margin:12px 0 4px;text-wrap:balance}";
      print ".sub{color:var(--mut);font:500 13px/1.4 ui-monospace,Menlo,monospace}";
      print ".stats{display:grid;grid-template-columns:repeat(auto-fit,minmax(150px,1fr));gap:12px;margin:28px 0}";
      print ".card{background:var(--panel);border:1px solid var(--line);border-radius:10px;padding:16px 18px}";
      print ".card .k{color:var(--mut);font:600 11px/1 ui-monospace,monospace;letter-spacing:.08em;text-transform:uppercase}";
      print ".card .v{margin-top:8px;font:700 24px/1 ui-monospace,Menlo,monospace;font-variant-numeric:tabular-nums;color:#eef2f4}";
      print ".card .v.acc{color:var(--acc)}";
      print ".panel{background:var(--panel);border:1px solid var(--line);border-radius:12px;overflow:hidden}";
      print "table{width:100%;border-collapse:collapse;font-variant-numeric:tabular-nums}";
      print "th,td{text-align:right;padding:11px 14px;font:500 13px/1.3 ui-monospace,Menlo,monospace;white-space:nowrap}";
      print "th{color:var(--mut);font-size:10px;letter-spacing:.1em;text-transform:uppercase;border-bottom:1px solid var(--line);font-weight:600}";
      print "td:first-child,th:first-child{text-align:left}";
      print "tbody tr{border-bottom:1px solid var(--line)}tbody tr:last-child{border-bottom:0}";
      print ".proj{color:#eef2f4;font-weight:600}.bar{position:relative;height:5px;background:#1e262c;border-radius:3px;margin-top:6px;overflow:hidden}";
      print ".bar span{position:absolute;inset:0 auto 0 0;background:linear-gradient(90deg,var(--accd),var(--acc));border-radius:3px}";
      print ".cost{color:var(--acc);font-weight:700}.mut{color:var(--mut)}";
      print ".note{margin:22px 2px 0;color:var(--mut);font-size:12.5px;line-height:1.6;border-left:2px solid var(--accd);padding-left:12px}";
      print "footer{margin-top:14px;color:#5f6a71;font:500 12px/1.5 ui-monospace,monospace}";
      print "@media(max-width:560px){.hide-sm{display:none}h1{font-size:24px}}";
      print "</style>";
      print "<div class=\"wrap\"><div class=\"eyebrow\">Claude Code · 토큰 사용량</div>";
      print "<h1>프로젝트별 소비 개요</h1>";
      printf "<div class=\"sub\">%s · %s~%s · 생성 %s</div>\n", period, min, max, gen;
      print "<div class=\"stats\">";
      printf "<div class=\"card\"><div class=\"k\">총 환산가치</div><div class=\"v acc\">%s</div></div>\n", usd(Tcost);
      printf "<div class=\"card\"><div class=\"k\">총 토큰</div><div class=\"v\">%s</div></div>\n", hum(Ttok);
      printf "<div class=\"card\"><div class=\"k\">프로젝트</div><div class=\"v\">%d</div></div>\n", k;
      printf "<div class=\"card\"><div class=\"k\">총 호출</div><div class=\"v\">%s</div></div>\n", hum(Tn);
      print "</div>";
      print "<div class=\"panel\"><table><thead><tr><th>프로젝트</th><th>환산$</th><th class=\"hide-sm\">총 토큰</th><th class=\"hide-sm\">출력</th><th>호출</th><th class=\"hide-sm\">기간</th></tr></thead><tbody>";
      for(i=1;i<=k;i++){pr=K[i]; w=(mx>0)?int(Pcost[pr]/mx*100):0;
        printf "<tr><td><div class=\"proj\">%s</div><div class=\"bar\"><span style=\"width:%d%%\"></span></div></td>", esc(pr), w;
        printf "<td class=\"cost\">%s</td><td class=\"hide-sm mut\">%s</td><td class=\"hide-sm mut\">%s</td><td>%s</td><td class=\"hide-sm mut\">%s~%s</td></tr>\n",
          usd(Pcost[pr]), hum(Ptok[pr]), hum(Pout[pr]), hum(Pn[pr]), Pmin[pr], Pmax[pr];
      }
      print "</tbody></table></div>";
      print "<p class=\"note\"><strong style=\"color:var(--tx)\">$ 는 실제 청구가 아닙니다.</strong> 종량제 API 단가로 환산한 상대 소비량입니다(Pro/Max는 정액). 캐시읽기 0.1×·캐시쓰기 1.25× 근사. 실시간 캡 잔량은 대화형 <code>claude</code>에서 <code>/usage</code>.</p>";
      print "<footer>재생성: <code>bash usage-report.sh --html && open usage.html</code></footer>";
      print "</div></body></html>";
    }' > "$OUT"
  echo "생성: $OUT"
  command -v open >/dev/null && open "$OUT"
  exit 0
fi

# 인자 파싱: 첫 인자가 숫자면 '개요+일수', 아니면 '프로젝트'
PROJ=""; DAYS=0
if [ $# -ge 1 ]; then
  case "$1" in
    ''|*[!0-9]*) PROJ="$1"; DAYS="${2:-0}" ;;   # 프로젝트명
    *)           DAYS="$1" ;;                    # 숫자 → 개요 기간
  esac
fi

if [ "$DAYS" -gt 0 ] 2>/dev/null; then
  CUTOFF="$(date -v-"${DAYS}"d +%Y-%m-%d 2>/dev/null || date -d "-${DAYS} days" +%Y-%m-%d)"
  PERIOD="최근 ${DAYS}일"
else
  CUTOFF="0000-00-00"; PERIOD="전체 기간"
fi

if [ -n "$PROJ" ]; then
  finder() { find "$BASE" -maxdepth 1 -mindepth 1 -type d -iname "*${PROJ}*"; }
  MODE="detail"
else
  finder() { find "$BASE" -maxdepth 1 -mindepth 1 -type d; }
  MODE="overview"
fi
[ -n "$(finder)" ] || { echo "대상 프로젝트 없음: '$PROJ'"; exit 1; }

# project<TAB>day<TAB>model<TAB>in<TAB>out<TAB>cacheRead<TAB>cacheCreate
emit() {
  finder | while IFS= read -r d; do
    proj="$(basename "$d")"
    case "$proj" in
      "$HOME_KEY")               proj="홈-CLI세션" ;;
      "$PROJ_KEY")               proj="프로젝트-루트" ;;
      -)                         proj="기타" ;;
      *) proj="${proj#"$PROJ_KEY"-}"; proj="${proj#"$HOME_KEY"-}" ;;
    esac
    cat "$d"/*.jsonl 2>/dev/null | jq -rc --arg cut "$CUTOFF" --arg p "$proj" '
      select(.type=="assistant" and (.message.usage != null))
      | (.timestamp[0:10]) as $day
      | select($day >= $cut)
      | [ $p, $day, (.message.model // "?"),
          (.message.usage.input_tokens // 0),
          (.message.usage.output_tokens // 0),
          (.message.usage.cache_read_input_tokens // 0),
          (.message.usage.cache_creation_input_tokens // 0) ] | @tsv' || true
  done
}

AWK_PRICE='
  function price(m) {
    if (m ~ /opus/)        return "5 25";
    else if (m ~ /haiku/)  return "1 5";
    else if (m ~ /sonnet/) return "3 15";
    else if (m ~ /glm/)    return "0.6 2.2";
    else                   return "3 15";
  }
  function money(c){ return (c>=1000)? sprintf("%.0f",c) : sprintf("%.2f",c) }
'

if [ "$MODE" = "overview" ]; then
  echo "▶ [전 프로젝트 개요]  기간: $PERIOD  |  소비순  |  \$=API 환산가치(실청구 아님)"
  echo
  emit | awk -F'\t' "$AWK_PRICE"'
    {
      proj=$1; day=$2; model=$3; ini=$4; out=$5; cr=$6; cc=$7;
      split(price(model),p," "); cost=(ini*p[1]+cr*p[1]*0.1+cc*p[1]*1.25+out*p[2])/1e6;
      Pcost[proj]+=cost; Pout[proj]+=out; Ptok[proj]+=ini+out+cr+cc; Pn[proj]++;
      if (Pmin[proj]==""||day<Pmin[proj]) Pmin[proj]=day;
      if (day>Pmax[proj]) Pmax[proj]=day;
      Tcost+=cost; Ttok+=ini+out+cr+cc; Tout+=out; Tn++;
    }
    END{
      if(Tn==0){print "  (기록 없음)"; exit}
      printf "%-30s %7s %11s %11s %9s  %s\n","프로젝트","호출","출력tok","총tok","환산$","기간";
      # 비용 내림차순 정렬
      k=0; for(pr in Pcost) K[++k]=pr;
      for(i=1;i<k;i++)for(j=i+1;j<=k;j++) if(Pcost[K[j]]>Pcost[K[i]]){t=K[i];K[i]=K[j];K[j]=t}
      for(i=1;i<=k;i++){pr=K[i];
        printf "%-30s %7d %11d %11d %9s  %s~%s\n",
          substr(pr,1,30), Pn[pr], Pout[pr], Ptok[pr], money(Pcost[pr]), Pmin[pr], Pmax[pr];
      }
      printf "%-30s %7d %11d %11d %9s\n","─ 합계",Tn,Tout,Ttok,money(Tcost);
      printf "\n총 환산가치 ≈ \$%.2f  (Pro/Max는 정액 — 상대 소비량 참고용)\n",Tcost;
    }'
else
  echo "▶ [$PROJ 상세]  기간: $PERIOD  |  \$=API 환산가치(실청구 아님)"
  echo
  emit | awk -F'\t' "$AWK_PRICE"'
    {
      day=$2; model=$3; ini=$4; out=$5; cr=$6; cc=$7;
      split(price(model),p," "); cost=(ini*p[1]+cr*p[1]*0.1+cc*p[1]*1.25+out*p[2])/1e6;
      Min[model]+=ini;Mout[model]+=out;Mcr[model]+=cr;Mcost[model]+=cost;Mn[model]++;
      Dcost[day]+=cost;Dout[day]+=out;
      Tin+=ini;Tout+=out;Tcr+=cr;Tcc+=cc;Tcost+=cost;Tn++;
    }
    END{
      if(Tn==0){print "  (기간 내 기록 없음)";exit}
      printf "── 모델별 ───────────────────────────────────────\n";
      printf "%-20s %7s %10s %10s %10s %8s\n","모델","호출","입력","출력","캐시읽기","환산$";
      for(m in Mcost) printf "%-20s %7d %10d %10d %10d %8s\n",m,Mn[m],Min[m],Mout[m],Mcr[m],money(Mcost[m]);
      printf "\n── 일자별 ───────────────────────────────────────\n";
      n=0;for(dd in Dcost)days[++n]=dd;
      for(i=1;i<n;i++)for(j=i+1;j<=n;j++)if(days[j]<days[i]){t=days[i];days[i]=days[j];days[j]=t}
      for(i=1;i<=n;i++){dd=days[i];printf "%-12s 출력 %9d tok  환산 $%s\n",dd,Dout[dd],money(Dcost[dd])}
      printf "\n── 합계 ─────────────────────────────────────────\n";
      printf "호출 %d | 입력 %d | 출력 %d | 캐시읽기 %d | 캐시쓰기 %d\n",Tn,Tin,Tout,Tcr,Tcc;
      printf "총 토큰 %d | ★환산가치 $%.2f (실청구 아님)\n",Tin+Tout+Tcr+Tcc,Tcost;
    }'
fi
