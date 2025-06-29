document.addEventListener("DOMContentLoaded", function () {
    const button = document.getElementById("hey-button");

    button.addEventListener("click", function () {
        console.log("Button was clicked!");
        fetch("/button-click", {
            method: "POST",
            headers: {
                "Content-Type": "text/plain",
            },
            body: "A button was pressed",
        })
            .then((res) => {
                if (!res.ok) {
                    throw new Error(`Server error: ${res.status}`);
                }
                return res.text();
            })
            .then((data) => {
                console.log("server response:", data);
            })
            .catch((err) => {
                console.error("request failed:", err);
            });
    });
});
