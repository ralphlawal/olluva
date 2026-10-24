// Small, dependency-free behaviour for www.olluva.app. Everything here is an
// enhancement: the page reads fully without it, and all motion stops when the
// visitor has asked their device to reduce motion.
(function () {
  "use strict";
  var reduce = window.matchMedia("(prefers-reduced-motion: reduce)").matches;

  // The header gains a backdrop once the page has moved.
  var header = document.querySelector(".site-header");
  function onScroll() {
    if (header) header.classList.toggle("scrolled", window.scrollY > 8);
  }
  onScroll();
  window.addEventListener("scroll", onScroll, { passive: true });

  // Sections ease in as they reach the viewport.
  var revealing = document.querySelectorAll(".reveal");
  if (reduce || !("IntersectionObserver" in window)) {
    revealing.forEach(function (el) { el.classList.add("in"); });
  } else {
    var observer = new IntersectionObserver(function (entries) {
      entries.forEach(function (entry) {
        if (entry.isIntersecting) {
          entry.target.classList.add("in");
          observer.unobserve(entry.target);
        }
      });
    }, { rootMargin: "0px 0px -8% 0px", threshold: 0.12 });
    revealing.forEach(function (el) { observer.observe(el); });
  }

  // The widget on the band changes note every few seconds, the way a partner's
  // notes arrive. It pauses while it is off screen.
  var live = document.querySelector(".live");
  if (live) {
    var slides = live.querySelectorAll(".slide");
    var index = 0;
    var timer = null;
    function next() {
      slides[index].classList.remove("on");
      index = (index + 1) % slides.length;
      slides[index].classList.add("on");
    }
    function start() { if (!timer) timer = window.setInterval(next, 3200); }
    function stop() { window.clearInterval(timer); timer = null; }
    if ("IntersectionObserver" in window) {
      new IntersectionObserver(function (entries) {
        entries[0].isIntersecting ? start() : stop();
      }).observe(live);
    } else {
      start();
    }
  }

  // A gentle depth to the hero's notes as the page scrolls.
  var notes = document.querySelectorAll("[data-depth]");
  if (!reduce && notes.length) {
    var ticking = false;
    window.addEventListener("scroll", function () {
      if (ticking) return;
      ticking = true;
      window.requestAnimationFrame(function () {
        var y = Math.min(window.scrollY, 700);
        notes.forEach(function (note) {
          note.style.translate = "0 " + (-y * parseFloat(note.dataset.depth)).toFixed(1) + "px";
        });
        ticking = false;
      });
    }, { passive: true });
  }
})();
