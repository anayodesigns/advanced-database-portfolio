-- Q6 Support desk: find a rider by email typed in any case.
SELECT rider_id, full_name, email, phone, status
FROM swiftmove.rider
WHERE lower(email) = lower('Musa.Afolabi10007@MAIL.EXAMPLE')
