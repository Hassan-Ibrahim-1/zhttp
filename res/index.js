document.addEventListener("DOMContentLoaded", function () {
    const form = document.getElementById("name-form");
    form.addEventListener("submit", async (ev) => {
        ev.preventDefault();
        const name = document.getElementById("name").value;
        fetch("/submit-form", {
            method: "POST",
            headers: {
                "Content-Type": "application/json",
            },
            body: JSON.stringify({ name }),
        })
            .then((res) => {
                if (!res.ok) {
                    throw new Error(`Server error: ${res}`);
                }
                return res.json();
            })
            .then((res) => {
                console.log("Server response:", res);
            })
            .catch((err) => {
                console.error("Request failed:", err);
            });
    });
});
