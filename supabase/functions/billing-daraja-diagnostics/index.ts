import { serve } from "https://deno.land/std@0.168.0/http/server.ts";

const corsHeaders = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type, x-test-key",
};

const json = (body: unknown, status = 200) =>
  new Response(JSON.stringify(body, null, 2), {
    status,
    headers: { ...corsHeaders, "Content-Type": "application/json" },
  });

const clean = (name: string, fallback = "") =>
  (Deno.env.get(name) || fallback).trim();

const mask = (value: string) =>
  value.length > 8
    ? `${value.slice(0, 4)}...${value.slice(-4)} (${value.length} chars)`
    : `${value.length} chars`;

const kenyaTimestamp = () => {
  const parts = new Intl.DateTimeFormat("en-GB", {
    timeZone: "Africa/Nairobi",
    year: "numeric",
    month: "2-digit",
    day: "2-digit",
    hour: "2-digit",
    minute: "2-digit",
    second: "2-digit",
    hour12: false,
  }).formatToParts(new Date());
  const get = (type: string) => parts.find((part) => part.type === type)?.value || "";
  return `${get("year")}${get("month")}${get("day")}${get("hour")}${get("minute")}${get("second")}`;
};

const normalizePhone = (value: unknown) => {
  let phone = String(value || "").replace(/\D/g, "");
  if (phone.startsWith("0")) phone = `254${phone.slice(1)}`;
  if (phone.startsWith("7") || phone.startsWith("1")) phone = `254${phone}`;
  return phone;
};

serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: corsHeaders });
  if (req.method !== "POST") return json({ ok: false, error: "Use POST." }, 405);

  try {
    const body = await req.json().catch(() => ({}));
    const expectedTestKey = clean("BILLING_DIAGNOSTIC_KEY");
    const suppliedTestKey = String(req.headers.get("x-test-key") || body.test_key || "").trim();

    if (!expectedTestKey || suppliedTestKey !== expectedTestKey) {
      return json({ ok: false, error: "Invalid diagnostic test key." }, 401);
    }

    const phone = normalizePhone(body.phone);
    if (!/^254(7|1)\d{8}$/.test(phone)) {
      return json({ ok: false, error: "Enter a valid Safaricom number, for example 2547XXXXXXXX." }, 400);
    }

    const consumerKey = clean("DARAJA_CONSUMER_KEY");
    const consumerSecret = clean("DARAJA_CONSUMER_SECRET");
    const passkey = clean("DARAJA_PASSKEY");
    const shortcode = clean("DARAJA_SHORTCODE");
    const transactionType = clean("DARAJA_TRANSACTION_TYPE", "CustomerPayBillOnline");
    const accountReference = clean("BILLING_ACCOUNT_REFERENCE", "RUDDERDATA");
    const description = clean("BILLING_DESCRIPTION", "Wamama Pamoja subscription");
    const amount = Number(clean("BILLING_AMOUNT", "6000"));

    const missing = [
      ["DARAJA_CONSUMER_KEY", consumerKey],
      ["DARAJA_CONSUMER_SECRET", consumerSecret],
      ["DARAJA_PASSKEY", passkey],
      ["DARAJA_SHORTCODE", shortcode],
    ].filter(([, value]) => !value).map(([name]) => name);

    if (missing.length || !Number.isFinite(amount) || amount <= 0) {
      return json({
        ok: false,
        error: missing.length ? `Missing secrets: ${missing.join(", ")}` : "BILLING_AMOUNT must be a positive number.",
      }, 500);
    }

    const auth = btoa(`${consumerKey}:${consumerSecret}`);
    const oauthResponse = await fetch(
      "https://api.safaricom.co.ke/oauth/v1/generate?grant_type=client_credentials",
      { headers: { Authorization: `Basic ${auth}` } },
    );
    const oauthBody = await oauthResponse.json().catch(() => ({}));
    if (!oauthResponse.ok || !oauthBody.access_token) {
      return json({
        ok: false,
        message: "Daraja OAuth failed.",
        report: { status: oauthResponse.status, response: oauthBody },
      }, 502);
    }

    const timestamp = kenyaTimestamp();
    const password = btoa(`${shortcode}${passkey}${timestamp}`);
    const callbackUrl = `${clean("SUPABASE_URL")}/functions/v1/billing-payment-callback`;
    const stkPayload = {
      BusinessShortCode: Number(shortcode),
      Password: password,
      Timestamp: timestamp,
      TransactionType: transactionType,
      Amount: amount,
      PartyA: Number(phone),
      PartyB: Number(shortcode),
      PhoneNumber: Number(phone),
      CallBackURL: callbackUrl,
      AccountReference: accountReference,
      TransactionDesc: description,
    };

    const stkResponse = await fetch(
      "https://api.safaricom.co.ke/mpesa/stkpush/v1/processrequest",
      {
        method: "POST",
        headers: {
          Authorization: `Bearer ${oauthBody.access_token}`,
          "Content-Type": "application/json",
        },
        body: JSON.stringify(stkPayload),
      },
    );
    const stkBody = await stkResponse.json().catch(() => ({}));
    const accepted = stkResponse.ok && String(stkBody.ResponseCode) === "0";

    return json({
      ok: accepted,
      message: accepted
        ? `STK prompt accepted for KES ${amount.toLocaleString("en-KE")}. Cancel it on the phone without entering your PIN.`
        : "STK request failed. Check the response below.",
      report: {
        amount,
        phone,
        secrets_seen: {
          DARAJA_CONSUMER_KEY: mask(consumerKey),
          DARAJA_CONSUMER_SECRET: mask(consumerSecret),
          DARAJA_PASSKEY: mask(passkey),
          DARAJA_SHORTCODE: mask(shortcode),
          DARAJA_TRANSACTION_TYPE: transactionType,
          BILLING_AMOUNT: amount,
          BILLING_ACCOUNT_REFERENCE: accountReference,
        },
        oauth: { ok: true, status: oauthResponse.status },
        stk: { ok: accepted, status: stkResponse.status, response: stkBody },
      },
    }, accepted ? 200 : 502);
  } catch (error) {
    return json({ ok: false, error: error instanceof Error ? error.message : String(error) }, 500);
  }
});
