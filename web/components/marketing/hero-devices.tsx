import { EchoMark } from "@/components/brand/echo-mark";

/**
 * The hero device scene (web/DESIGN.md §4): a real MacBook showing a capture in
 * progress (article + warm-glass overlay) beside an iPhone showing the review
 * card. The MacBook proves *capture*, the iPhone proves *echo* — the two devices
 * are the loop. Screens use the FIXED device palette (light in both themes).
 * Styling lives in app/marketing.css (.m-* classes).
 */
export function HeroDevices() {
  return (
    <div className="m-stagewrap" aria-hidden="true">
      <div className="m-stage">
        {/* MacBook — capture in progress */}
      <div className="m-laptop">
        <div className="m-lid">
          <div className="m-display">
            <div className="m-notch" />
            <span className="m-glare" />
            <div className="m-art">
              <div className="src">The Hearth · Essay</div>
              <h3>The quiet hours</h3>
              <p>
                There was a stillness to the early city she had never quite been
                able to name — a low,{" "}
                <span className="m-tgt">ineffable</span>
                <span className="m-caret" /> sense that the streets were holding
                their breath, waiting for the day to be given permission to begin.
              </p>
            </div>
            <div className="m-ovl">
              <div className="hw">ineffable</div>
              <div className="pos">adjective</div>
              <div className="mean">
                too great or extreme to be expressed or described in words.
              </div>
              <div className="field">
                <span className="flab">Your sentence</span>
                <span className="ctx">
                  …a low, ineffable sense that the streets were holding their
                  breath
                </span>
              </div>
              <div className="row">
                <span className="lang">Learning: English ▾</span>
                <span className="save">
                  <span className="dot" />
                  Save
                </span>
              </div>
            </div>
          </div>
        </div>
        <div className="m-deck" />
      </div>

      {/* iPhone — review (echo back) */}
      <div className="m-phone">
        <div className="m-pframe">
          <div className="m-pscreen">
            <span className="m-pglare" />
            <div className="m-island" />
            <div className="m-pstat">
              <span className="t">9:41</span>
              <span className="ico">
                <svg
                  width="16"
                  height="12"
                  viewBox="0 0 16 12"
                  fill="none"
                  stroke="currentColor"
                  strokeWidth="1.5"
                  strokeLinecap="round"
                >
                  <path d="M2 4.2a9 9 0 0 1 12 0" />
                  <path d="M4.4 6.8a5.5 5.5 0 0 1 7.2 0" />
                  <circle cx="8" cy="9.7" r="1" fill="currentColor" stroke="none" />
                </svg>
                <svg width="26" height="13" viewBox="0 0 26 13" fill="none">
                  <rect
                    x="0.5"
                    y="1.5"
                    width="21"
                    height="10"
                    rx="2.6"
                    stroke="currentColor"
                    strokeWidth="1"
                    opacity=".45"
                  />
                  <rect x="2" y="3" width="16" height="7" rx="1.3" fill="currentColor" />
                  <rect
                    x="23"
                    y="4.6"
                    width="1.8"
                    height="3.8"
                    rx=".9"
                    fill="currentColor"
                    opacity=".45"
                  />
                </svg>
              </span>
            </div>
            <div className="m-prev">
              <div className="ph-top">
                <span className="lab">
                  <EchoMark className="size-[18px]" />
                  Review
                </span>
                <span className="meta">№ 047 · DUE TODAY</span>
              </div>
              <div className="pctx">
                a low, <span className="hl">ineffable</span> sense that the streets
                were holding their breath.
              </div>
              <div className="answer">
                <div className="w">ineffable</div>
                <div className="ipa">/ɪnˈɛfəb(ə)l/ · adjective</div>
                <EchoMark className="echo size-6" />
              </div>
              <div className="m-rate">
                <span>Forget</span>
                <span>Hard</span>
                <span className="good">Good</span>
                <span>Easy</span>
              </div>
            </div>
          </div>
        </div>
      </div>
      </div>
    </div>
  );
}
